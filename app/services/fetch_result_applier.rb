# fetcher (Rust) が送ってきた取得結果を保存する。ChannelItemsUpdaterJob と同じ順番で、
# リダイレクト → チャンネル情報 → item → チェック済みの記録と再計算 を行う。
# 各手順の例外は Sentry に送って次の手順に進む (ジョブの handle_error と同じ考え方)。
# fetcher の整形済みの値をそのまま信じず、保存は ActiveRecord のバリデーションとコールバックを通す
class FetchResultApplier
  # これより多い entries は、リクエストの中では保存せず FetchResultApplyJob に任せる (Heroku のルーターは30秒で打ち切る)
  ITEMS_IN_REQUEST_LIMIT = 200
  CHANNEL_ATTRIBUTES = %w[title description site_url image_url applied_filters filter_details].freeze
  # 取得に失敗しても last_items_checked_at は進むので、遅れの監視では気づけない。
  # 何度やっても同じように失敗しそうな種類 (フィードを解釈できない・大きすぎる・時間内に処理しきれない) だけを Sentry に送る。
  # http_status・timeout・connect などはサイト側の一時的な不調が多く、数も多いのでログだけにする
  REPORTED_FAILURE_KINDS = %w[parse too_large deadline].freeze

  def self.valid_payload?(payload)
    return false unless payload.is_a?(Hash) && [ true, false ].include?(payload["fetched"])
    return true unless payload["fetched"]

    payload["entries"].is_a?(Array) && payload["entries"].all?(Hash) &&
      payload["latest_guids"].is_a?(Array) &&
      (payload["channel"].nil? || payload["channel"].is_a?(Hash)) &&
      (payload["register_proxy_urls"].nil? || payload["register_proxy_urls"].is_a?(Array))
  end

  def initialize(channel:)
    @channel = channel
  end

  # 取得失敗・リダイレクトの処理を行い、item の保存に進んでよいかを返す
  def apply_channel!(payload)
    unless payload["fetched"]
      error = payload["error"] || {}
      Rails.logger.info "[FetchResultApplier] Channel #{@channel.id} fetch failed - #{error['kind']}: #{error['message']}"
      report_failure(error["kind"], error["message"]) if REPORTED_FAILURE_KINDS.include?(error["kind"])
      return false
    end

    step("Failed to register proxy domain") { Array(payload["register_proxy_urls"]).each { ProxyRequiredDomain.register!(_1) } }
    # リダイレクトの処理で例外が出たら、今の fetch_and_save_items と同じく item は保存しない
    return false unless step("Failed to follow redirect") { follow_redirect(payload["final_url"]) } == :ok

    step("Failed to update channel info") { update_info(payload["channel"]) }
    true
  end

  def save_items!(entries, latest_guids:)
    notifiable = latest_guids.to_set
    counts = { created: 0, skipped: 0 }

    entries.each do |entry|
      # channel.items を通さない。無効な Item が association のキャッシュに残らないようにする (#828)
      item = Item.new(
        channel_id: @channel.id, guid: entry["guid"], title: entry["title"], url: entry["url"],
        image_url: entry["image_url"], published_at: entry["published_at"], data: entry["data"]
      )
      if item.save
        counts[:created] += 1
        ItemCreationNotifierJob.perform_later(item.id) if notifiable.include?(item.guid)
      else
        counts[:skipped] += 1
        # 同じ guid が既に保存されている (別の取得と重なった) のはデータの問題ではないのでログにも残さない
        log_invalid(entry, item) unless item.errors.of_kind?(:guid, :taken)
      end
    rescue ActiveRecord::RecordNotUnique
      counts[:skipped] += 1
    rescue StandardError => e
      counts[:skipped] += 1
      Sentry.capture_exception(e, extra: { channel_id: @channel.id, channel_title: @channel.title,
                                           item_title: entry["title"], item_guid: entry["guid"] })
    end

    counts
  end

  def finish!
    step("Failed to mark items checked") { @channel.mark_items_checked! }
    step("Failed to set check interval") { @channel.set_check_interval! }
    step("Failed to adjust schedules") { @channel.adjust_schedules! }
  end

  private

  def follow_redirect(final_url)
    return :ok if final_url.blank? || final_url == @channel.feed_url

    Rails.logger.info "[FetchResultApplier] Detected redirect from #{@channel.feed_url} to #{final_url}, updating channel ##{@channel.id}"
    @channel.update!(feed_url: final_url)
    :ok
  rescue ActiveRecord::RecordInvalid => e
    raise unless e.record.errors.of_kind?(:feed_url, :taken)

    @channel.reload
    existing = Channel.find_by(feed_url: final_url)
    Rails.logger.warn "[FetchResultApplier] Redirect target #{final_url} already exists as channel ##{existing&.id}, stopping channel ##{@channel.id}"
    ChannelStopper.find_or_create_by!(channel: @channel) do |stopper|
      stopper.reason = "Redirect target #{final_url} already exists as channel ##{existing&.id}"
    end
    :stopped
  end

  # Channel.save_from と同じく bang なしで更新する (バリデーションに落ちたら更新せずに進む)。
  # 重要な項目が変われば notify_channel_change (after_commit) が Discord に知らせる
  def update_info(attributes)
    return if attributes.nil?

    @channel.update(attributes.slice(*CHANNEL_ATTRIBUTES))
  end

  def report_failure(kind, message)
    Sentry.capture_message(
      "Fetcher could not process the feed: #{kind} - channel_id: #{@channel.id}",
      level: :warning,
      fingerprint: [ "fetcher-feed-failure", kind, @channel.id.to_s ],
      extra: { channel_id: @channel.id, feed_url: @channel.feed_url, kind:, message: }
    )
  end

  # バリデーションに落ちた entry は次の取得でも同じように落ちるので、Sentry には送らずログに留める
  def log_invalid(entry, item)
    messages = item.errors.full_messages.join(", ")
    Rails.logger.warn "[FetchResultApplier] Skipped item (validation) - Channel: #{@channel.id}, Item: #{entry['title']} - #{messages}"
  end

  # ブロックの値を返す。例外なら Sentry に送って :failed を返す
  def step(context)
    yield
  rescue StandardError => e
    Sentry.capture_exception(e, extra: { channel_id: @channel.id, channel_title: @channel.title,
                                         feed_url: @channel.feed_url, context: })
    message = e.message.dup.force_encoding(Encoding::UTF_8).scrub
    Rails.logger.error "[FetchResultApplier] #{context} - Channel: #{@channel.id} - Error: #{e.class.name}: #{message}"
    :failed
  end
end
