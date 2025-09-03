class Channel < ApplicationRecord
  include Rails.application.routes.url_helpers
  include Stripable
  include EmptyStringsAreAlignedToNil
  include UrlHttpValidator

  has_many :items, dependent: :destroy
  has_many :ownerships, dependent: :destroy
  has_many :owners, through: :ownerships, source: :user
  has_many :subscriptions, dependent: :destroy
  has_many :subscribers, through: :subscriptions, source: :user
  has_many :channel_groupings, dependent: :destroy
  has_many :groups, through: :channel_groupings, source: :channel_group
  has_one :stopper, class_name: "ChannelStopper", dependent: :destroy
  has_many :fixed_schedules, class_name: "ChannelFixedSchedule", dependent: :destroy

  validates :title, presence: true, length: { maximum: 256 }
  validates :description, length: { maximum: 1024 }
  validates :feed_url, presence: true, uniqueness: true
  validates_url_http_format_of :feed_url, :site_url, :image_url

  strip_before_save :title, :description
  empty_strings_are_aligned_to_nil :description, :site_url, :image_url
  after_commit :notify_channel_change, on: %i[ create update ]
  after_create_commit { ChannelItemsUpdaterJob.perform_later(channel_id: self.id, mode: :all) }

  scope :not_stopped, -> { where.missing(:stopper) }
  scope :scheduled_for_current_hour, -> {
    joins(:fixed_schedules)
      .merge(ChannelFixedSchedule.for_current_hour)
      .distinct
  }
  scope :needs_check_now, -> {
    # 通常の間隔ベースのチェック
    interval_check = where(last_items_checked_at: nil)
      .or(where("last_items_checked_at < NOW() - ((check_interval_hours || ' hours')::interval - interval '10 minutes')"))

    # スケジュールベースのチェック（現在の時間帯に設定されているもの）
    schedule_check = scheduled_for_current_hour

    # 両方をORで結合（重複は自動的に排除される）
    where(id: interval_check).or(where(id: schedule_check))
  }
  scope :by_check_priority, -> {
    order(:check_interval_hours, :last_items_checked_at)
  }

  # トップページ用のスコープ
  scope :recent, -> { order(id: :desc) }
  scope :with_recent_activity, -> {
    joins(:items)
      .select("channels.*, MAX(items.id) AS max_item_id")
      .group("channels.id")
      .order("max_item_id DESC")
  }

  class << self
    def ransackable_attributes(auth_object = nil)
      %w[title description site_url feed_url]
    end

    def ransackable_associations(auth_object = nil)
      []
    end

    def fetch_and_save_items
      not_stopped.needs_check_now.by_check_priority.find_each do |channel|
        ChannelItemsUpdaterJob.perform_later(channel_id: channel.id)
      end
    end

    def adjust_all_check_intervals
      total = not_stopped.count
      updated = 0

      not_stopped.find_each do |channel|
        channel.set_check_interval!
        updated += 1
        Rails.logger.info "Channel #{channel.id} interval adjusted to #{channel.check_interval_hours} hours"
      end

      Rails.logger.info "Auto-adjusted check intervals for #{updated}/#{total} channels"
      updated
    end

    def adjust_all_schedules!
      total_added = 0
      total_removed = 0
      skipped_insufficient = 0
      skipped_inactive = 0

      not_stopped.find_each do |channel|
        if channel.items.count < 20
          skipped_insufficient += 1
          next
        end

        result = channel.adjust_schedules!
        total_added += result[:added].count
        total_removed += result[:removed].count

        # 非アクティブなチャンネルかどうかを判定（adjust_schedules!内で判定・処理済み）
        if result[:added].empty? && result[:removed].any?
          latest_item = channel.items.order(published_at: :desc).first
          if latest_item.published_at < 1.month.ago
            skipped_inactive += 1
          end
        end
      end

      Rails.logger.info "Schedule adjustment completed: #{total_added} added, #{total_removed} removed"
      Rails.logger.info "Skipped: #{skipped_insufficient} channels (insufficient items), #{skipped_inactive} channels (inactive)"

      {
        added: total_added,
        removed: total_removed,
        skipped_insufficient: skipped_insufficient,
        skipped_inactive: skipped_inactive
      }
    end

    def add(url)
      feed = nil
      feed_url = nil

      begin
        feed = Feedjira.parse(Httpc.get(url))
        feed_url = url
      rescue Feedjira::NoParserAvailable
        feed_url = Feedbag.find(url).first
        feed = Feedjira.parse(Httpc.get(feed_url)) if feed_url
      end

      return nil if feed.nil?
      return nil if feed_url.nil?
      save_from(feed_url)
    end

    def preview(url)
      feed = nil
      feed_url = nil

      begin
        feed = Feedjira.parse(Httpc.get(url))
        feed_url = url
      rescue Feedjira::NoParserAvailable
        feed_url = Feedbag.find(url).first
        feed = Feedjira.parse(Httpc.get(feed_url)) if feed_url
      end

      return nil if feed.nil?
      return nil if feed_url.nil?

      feed.url = feed.url.strip if feed.url

      parameters = build_from(feed, feed_url)

      Channel.new(parameters.merge(feed_url: feed_url))
    end

    def save_from(feed_url)
      feed = Feedjira.parse(Httpc.get(feed_url))
      feed.url = feed.url.strip if feed.url

      parameters = build_from(feed, feed_url)

      channel = Channel.find_or_initialize_by(feed_url: feed_url)
      channel.update(parameters)
      channel
    end

    def build_from(feed, feed_url = nil)
      case feed
      when Feedjira::Parser::RSS
        build_from_rss(feed, feed_url)
      when Feedjira::Parser::Atom
        build_from_atom(feed, feed_url)
      when Feedjira::Parser::ITunesRSS
        build_from_itunes_rss(feed, feed_url)
      when Feedjira::Parser::AtomYoutube
        build_from_atom_youtube(feed, feed_url)
      end
    end

    def build_from_rss(feed, feed_url = nil)
      # feed.urlが相対パスの場合はfeed_urlを使う
      site_url = normalize_url(feed.url, feed_url)
      og = OpenGraph.new(site_url) rescue nil
      {
        title: feed.title,
        description: feed.description,
        site_url: site_url,
        image_url: og&.image
      }
    end

    def build_from_atom(feed, feed_url = nil)
      # feed.urlが相対パスの場合はfeed_urlを使う
      site_url = normalize_url(feed.url, feed_url)
      og = OpenGraph.new(site_url) rescue nil
      {
        title: feed.title,
        description: feed.description,
        site_url: feed.links.first || site_url,
        image_url: og&.image
      }
    end

    def build_from_itunes_rss(feed, feed_url = nil)
      site_url = normalize_url(feed.url, feed_url)
      {
        title: feed.title,
        description: feed.description,
        site_url: site_url,
        image_url: feed.itunes_image
      }
    end

    def build_from_atom_youtube(feed, feed_url = nil)
      site_url = normalize_url(feed.url, feed_url)
      og = OpenGraph.new(site_url) rescue nil
      {
        title: feed.title,
        description: og&.description,
        site_url: site_url,
        image_url: og&.image
      }
    end

    def normalize_url(url, feed_url)
      return feed_url if url.blank?

      # 絶対URLの場合はそのまま返す
      return url if url.start_with?("http://", "https://")

      # 相対URLの場合はfeed_urlのドメインを使って絶対URLに変換
      return feed_url unless feed_url

      begin
        uri = URI.parse(feed_url)
        base_url = "#{uri.scheme}://#{uri.host}#{uri.port != uri.default_port ? ":#{uri.port}" : ''}"

        if url.start_with?("/")
          "#{base_url}#{url}"
        else
          URI.join(base_url, url).to_s
        end
      rescue URI::InvalidURIError
        feed_url
      end
    end

    def similar_to(channel)
      Channel.ransack({
        g: { "0" => { m: "or", title_cont: channel.title, site_url_cont: channel.site_url } }
      }).result
    end

    def classify_urls(urls)
      existing_urls = []
      new_urls = []

      urls.each do |url|
        if exists?(feed_url: url)
          existing_urls << url
        else
          new_urls << url
        end
      end

      [ existing_urls, new_urls ]
    end

    # 最新のアイテムを持つチャンネルを効率的に取得
    def with_recent_items(limit: 12, items_per_channel: 3)
      channels = with_recent_activity.limit(limit)

      # 各チャンネルの最新アイテムを一括取得
      channel_ids = channels.map(&:id)
      return channels if channel_ids.empty?

      # Window関数で各Channelの上位N件を確実に取得
      sql = Item.connection.execute(
        ActiveRecord::Base.sanitize_sql_array([
          <<~SQL,
            WITH ranked_items AS (
              SELECT id, channel_id, guid, title, url, published_at,
                     created_at, updated_at, image_url, data,
                     ROW_NUMBER() OVER (PARTITION BY channel_id ORDER BY id DESC) as rn
              FROM items
              WHERE channel_id = ANY(ARRAY[?]::bigint[])
            )
            SELECT id, channel_id, guid, title, url, published_at,
                   created_at, updated_at, image_url, data
            FROM ranked_items
            WHERE rn <= ?
            ORDER BY channel_id, id DESC
          SQL
          channel_ids,
          items_per_channel
        ])
      )

      recent_items = sql.map { |row| Item.instantiate(row) }

      # メモリ上でグループ化（パフォーマンス最適化）
      items_by_channel = recent_items.group_by(&:channel_id)

      # 各チャンネルに最新アイテムを関連付け
      channels.each do |channel|
        items = items_by_channel[channel.id] || []
        channel.define_singleton_method(:recent_items) { items }
      end

      channels
    end
  end

  def update_info
    Channel.save_from(feed_url)
  end

  def fetch_and_save_items(mode = :only_non_existing)
    feed = Feedjira.parse(Httpc.get(feed_url))

    entries =
      if mode == :all
        feed.entries
      elsif mode == :only_non_existing
        feed.entries.reject {
          self.items.exists?(guid: _1.entry_id) ||
          self.items.exists?(guid: _1.url)
        }
      else
        # only_recent
        feed.entries.sort_by(&:published).reverse.take(10)
      end

    success_count = 0
    error_count = 0

    entries.sort_by(&:published).each do |entry|
      begin
        next if entry.title.blank?

        # フィルタを適用
        entry = apply_filters(entry)

        url = entry.url.presence ||
              (entry.respond_to?(:enclosure_url) && entry.enclosure_url.presence) ||
              self.site_url.presence

        next if url.blank?

        url = url.strip

        encoded_url = url.chars.map { |c|
          if c.bytesize > 1
            URI.encode_www_form_component(c)
          elsif c == '"'
            "%22"
          else
            c
          end
        }.join

        guid = entry.entry_id || entry.url

        image_url =
          if entry.respond_to?(:itunes_image) && entry.itunes_image
            entry.itunes_image
          elsif entry.respond_to?(:image) && entry.image
            entry.image
          elsif guid.start_with?("yt:video:")
            "https://img.youtube.com/vi/%s/maxresdefault.jpg" % guid.sub("yt:video:", "")
          else
            sleep 2
            OpenGraph.new(encoded_url).image rescue nil
          end

        parameters = {
          guid: guid,
          title: entry.title,
          url: encoded_url,
          image_url: image_url,
          published_at: entry.published,
          data: entry.to_h
        }
        item = self.items.find_or_initialize_by(guid: guid)

        if item.new_record?
          Rails.logger.info "[Channel] Saving new item: #{entry.title} (#{encoded_url})"
        end

        item.update!(parameters)
        success_count += 1
      rescue StandardError => e
        error_count += 1

        # Sentryにエラーを送信
        Sentry.capture_exception(e, extra: {
          channel_id: self.id,
          channel_title: self.title,
          item_title: entry.title,
          item_guid: entry.entry_id || entry.url,
          error_count: error_count,
          success_count: success_count
        })

        # コンパクトなログ出力
        Rails.logger.error "[Channel] Failed to save item - Channel: #{self.id}, Item: #{entry.title} - Error: #{e.class.name}: #{e.message}"
      end
    end

    # 処理結果のサマリーログ
    if error_count > 0
      Rails.logger.warn "[Channel] Item processing completed - Channel: #{self.id} - Success: #{success_count}, Errors: #{error_count}"
    end
  end

  def owned_by?(user)
    self.owners.exists?(id: user.id)
  end

  def subscribed_by?(user)
    self.subscribers.exists?(id: user.id)
  end

  def favicon_url
    url = site_url || items.order(id: :desc).first&.url
    return "" if url.nil?

    "https://www.google.com/s2/favicons?domain_url=#{URI.parse(url).host}"
  end

  def image_url_or_placeholder
    image_url.presence || "https://placehold.jp/30/cccccc/ffffff/300x300.png?text=#{URI.encode_www_form_component(self.title)}"
  end

  def mark_items_checked!
    update!(last_items_checked_at: Time.current)
  end

  def apply_filters(entry)
    return entry if applied_filters.blank?

    applied_filters.each do |filter_name|
      filter_class = "FeedFilters::#{filter_name}".constantize
      filter = filter_class.new

      if filter.applicable?(entry, self)
        entry = filter.apply(entry, self)

        # フィルタ適用の詳細を記録（必要に応じて）
        if filter.applied
          Rails.logger.info "[Channel#apply_filters] Applied #{filter_name} to entry"
        end
      end
    rescue NameError => e
      Rails.logger.error "[Channel#apply_filters] Filter not found: #{filter_name} - #{e.message}"
    rescue StandardError => e
      Rails.logger.error "[Channel#apply_filters] Error applying filter #{filter_name}: #{e.message}"
    end

    entry
  end

  def set_check_interval!
    # 各期間内のアイテム数をカウント
    items_1_week = items.where("published_at > ?", 1.week.ago).count
    items_2_weeks = items.where("published_at > ?", 2.weeks.ago).count
    items_1_month = items.where("published_at > ?", 1.month.ago).count
    items_2_months = items.where("published_at > ?", 2.months.ago).count

    interval = if items_1_week >= 3
                 1   # 1時間毎
    elsif items_2_weeks >= 2
                 3   # 3時間毎
    elsif items_1_month >= 2
                 4   # 4時間毎
    elsif items_2_months >= 1
                 12  # 12時間毎
    else
                 24  # 24時間毎（デフォルト）
    end

    update!(check_interval_hours: interval)
  end

  def add_schedule(day_of_week:, hour:)
    fixed_schedules.create!(
      day_of_week: day_of_week,
      hour: hour
    )
  end

  def remove_schedule(day_of_week:, hour:)
    fixed_schedules.find_by(day_of_week: day_of_week, hour: hour)&.destroy
  end

  def adjust_schedules!
    result = { added: [], removed: [] }

    # 十分なデータがない場合は何もしない
    return result if items.count < 20

    # 直近1ヶ月以内にアイテムがない場合は全スケジュールを削除
    latest_item = items.order(published_at: :desc).first
    if latest_item.published_at < 1.month.ago
      result[:removed] = fixed_schedules.pluck(:day_of_week, :hour)
      fixed_schedules.destroy_all
      return result
    end

    patterns = analyze_publishing_patterns(item_count: 20)
    current_schedules = fixed_schedules.pluck(:day_of_week, :hour).to_set

    # 条件を満たすパターンを追加
    patterns.select { |_, count| count >= 6 }.each do |(day_of_week, hour), _|
      next if current_schedules.include?([ day_of_week, hour ])

      begin
        add_schedule(day_of_week: day_of_week, hour: hour)
        result[:added] << [ day_of_week, hour ]
        Rails.logger.info "Added schedule for Channel ##{id}: #{day_of_week_name(day_of_week)} #{hour}:00"
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn "Failed to add schedule: #{e.message}"
      end
    end

    # 条件を満たさなくなったスケジュールを削除
    current_schedules.each do |day_of_week, hour|
      pattern_count = patterns[[ day_of_week, hour ]] || 0
      if pattern_count < 6
        remove_schedule(day_of_week: day_of_week, hour: hour)
        result[:removed] << [ day_of_week, hour ]
        Rails.logger.info "Removed schedule for Channel ##{id}: #{day_of_week_name(day_of_week)} #{hour}:00 (only #{pattern_count} items found)"
      end
    end

    result
  end

  def analyze_publishing_patterns(item_count: 20)
    recent_items = items.order(published_at: :desc).limit(item_count)

    # 曜日と時間帯のパターンをカウント
    patterns = Hash.new(0)

    recent_items.each do |item|
      next unless item.published_at

      # タイムゾーンを考慮（日本時間として処理）
      published_time = item.published_at.in_time_zone("Asia/Tokyo")
      day_of_week = published_time.wday
      hour = published_time.hour

      patterns[[ day_of_week, hour ]] += 1
    end

    # ソートして返す（頻度の高い順）
    patterns.sort_by { |_, count| -count }.to_h
  end

  def publishing_pattern_summary(item_count: 20)
    if items.count < 20
      return "Not enough items for analysis (minimum 20 required, current: #{items.count})"
    end

    latest_item = items.order(published_at: :desc).first
    if latest_item.published_at < 1.month.ago
      return "No recent activity (last item: #{latest_item.published_at.strftime('%Y-%m-%d')})"
    end

    patterns = analyze_publishing_patterns(item_count: item_count)
    current_schedules = fixed_schedules.pluck(:day_of_week, :hour).to_set

    summary = [ "Publishing patterns for #{title} (last #{item_count} items):" ]
    patterns.each do |(day_of_week, hour), count|
      percentage = (count.to_f / item_count * 100).round(1)
      status = if count >= 6
                 current_schedules.include?([ day_of_week, hour ]) ? "[Scheduled]" : "[Will be scheduled]"
      else
                 current_schedules.include?([ day_of_week, hour ]) ? "[Will be removed]" : ""
      end
      summary << "  %s %2d:00 - %d items (%5.1f%% ) %s" % [ day_of_week_name(day_of_week), hour, count, percentage, status ]
    end

    # 現在のスケジュールで、パターンに含まれないもの
    current_schedules.each do |day_of_week, hour|
      next if patterns.key?([ day_of_week, hour ])
      summary << "  %s %2d:00 - 0 items (0.0%) [Will be removed]" % [ day_of_week_name(day_of_week), hour ]
    end

    summary.join("\n")
  end

  def notify_channel_change
    prefix = previous_changes.key?(:id) ? "New channel created" : "Channel updated"
    # last_items_checked_atとupdated_atの変更は無視する
    ignored_fields = %w[last_items_checked_at updated_at created_at]
    significant_changes = previous_changes.except(*ignored_fields)

    changed_fields = significant_changes.keys.map { |field| "# #{field}\n- [Old] #{significant_changes[field].first}\n- [New] #{significant_changes[field].last}" }
    return if changed_fields.empty?

    content = [
      "[#{prefix}] #{title}",
      "```",
      changed_fields.join("\n\n"),
      "```"
    ].join("\n")

    DiscoPosterJob.perform_later(content: content)
  end

  def to_discord_more_embed
    {
      title: "Check out more recent items in #{title}",
      url: channel_url(self)
    }
  end

  def to_slack_header_block
    {
      type: "section",
      text: {
        type: "mrkdwn",
        text: "<%s|#{title}> 's recent items 📨" % [
          channel_url(self)
        ]
      }
    }
  end

  def to_slack_more_block
    {
      type: "section",
      text: {
        type: "mrkdwn",
        text: "Check out more recent items in <%s|#{title}>" % [
          channel_url(self)
        ]
      }
    }
  end

  private

  def day_of_week_name(day)
    %w[Sun Mon Tue Wed Thu Fri Sat][day]
  end
end
