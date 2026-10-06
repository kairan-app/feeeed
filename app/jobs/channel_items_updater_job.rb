class ChannelItemsUpdaterJob < ApplicationJob
  def perform(channel_id:, mode: :only_non_existing)
    channel = Channel.find(channel_id)

    begin
      channel.update_info
      # リダイレクトでfeed_urlが更新された場合、メモリ上のオブジェクトを最新の状態にする
      channel.reload
    rescue StandardError => e
      handle_error(e, channel, "Failed to update channel info")
    end

    begin
      channel.fetch_and_save_items(mode)
    rescue StandardError => e
      handle_error(e, channel, "Failed to fetch and save items")
    end

    begin
      channel.mark_items_checked!
    rescue StandardError => e
      handle_error(e, channel, "Failed to mark items checked")
    end

    begin
      channel.set_check_interval!
    rescue StandardError => e
      handle_error(e, channel, "Failed to set check interval")
    end

    begin
      channel.adjust_schedules!
    rescue StandardError => e
      handle_error(e, channel, "Failed to adjust schedules")
    end
  end

  private

  def handle_error(error, channel, context)
    report_to_sentry(error, channel, context)

    # コンパクトなログ出力
    # エラーメッセージはBINARYのことがあり、UTF-8のタイトルと混ぜると落ちるのでUTF-8に正規化する
    message = error.message.dup.force_encoding(Encoding::UTF_8).scrub
    logger.error "[ChannelItemsUpdaterJob] #{context} - Channel: #{channel.id} (#{channel.title}) - Error: #{error.class.name}: #{message}"
  end

  # Sentry の枠を外部要因の失敗で使い切らないよう、送るものを絞る (FetchResultApplier の REPORTED_FAILURE_KINDS と同じ考え方)
  # - HTTP の 4xx/5xx・タイムアウト・接続や SSL の失敗は、相手のサイトの不調なのでログだけにする
  # - フィードを解釈できないのは何度やっても同じように失敗しそうなので、warning としてチャンネルごとにまとめて送る。
  #   update_info と fetch_and_save_items が同じ理由で両方落ちるので、1回の実行で1件だけにする
  # - それ以外はアプリのバグの可能性があるので、例外として送る
  def report_to_sentry(error, channel, context)
    case error
    when *Httpc::EXTERNAL_ERRORS
      nil
    when Feedjira::NoParserAvailable
      return if @parse_failure_reported

      @parse_failure_reported = true
      Sentry.capture_message(
        "Could not parse the feed - channel_id: #{channel.id}",
        level: :warning,
        fingerprint: [ "feed-parse-failure", channel.id.to_s ],
        extra: { channel_id: channel.id, feed_url: channel.feed_url, context: context }
      )
    else
      Sentry.capture_exception(error, extra: {
        channel_id: channel.id,
        channel_title: channel.title,
        feed_url: channel.feed_url,
        context: context
      })
    end
  end
end
