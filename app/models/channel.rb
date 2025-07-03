class Channel < ApplicationRecord
  include Rails.application.routes.url_helpers
  include Stripable
  include EmptyStringsAreAlignedToNil
  include ValidationErrorsNotifiable
  include UrlHttpValidator

  has_many :items, dependent: :destroy
  has_many :ownerships, dependent: :destroy
  has_many :owners, through: :ownerships, source: :user
  has_many :subscriptions, dependent: :destroy
  has_many :subscribers, through: :subscriptions, source: :user
  has_many :channel_groupings, dependent: :destroy
  has_many :groups, through: :channel_groupings, source: :channel_group
  has_one :stopper, class_name: "ChannelStopper", dependent: :destroy

  validates :title, presence: true, length: { maximum: 256 }
  validates :description, length: { maximum: 1024 }
  validates :feed_url, presence: true, uniqueness: true
  validates_url_http_format_of :feed_url, :site_url, :image_url

  strip_before_save :title, :description
  empty_strings_are_aligned_to_nil :description, :site_url, :image_url
  after_commit :notify_channel_change, on: %i[ create update ]
  after_create_commit { ChannelItemsUpdaterJob.perform_later(channel_id: self.id, mode: :all) }

  scope :not_stopped, -> { where.missing(:stopper) }
  scope :needs_check_now, -> {
    where(last_items_checked_at: nil)
      .or(where('last_items_checked_at < NOW() - ((check_interval_hours || \' hours\')::interval - interval \'10 minutes\')'))
  }
  scope :by_check_priority, -> {
    order(:check_interval_hours, :last_items_checked_at)
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

      parameters = build_from(feed)

      Channel.new(parameters.merge(feed_url: feed_url))
    end

    def save_from(feed_url)
      feed = Feedjira.parse(Httpc.get(feed_url))
      feed.url = feed.url.strip if feed.url

      parameters = build_from(feed)

      channel = Channel.find_or_initialize_by(feed_url: feed_url)
      channel.update(parameters)
      channel
    end

    def build_from(feed)
      case feed
      when Feedjira::Parser::RSS
        build_from_rss(feed)
      when Feedjira::Parser::Atom
        build_from_atom(feed)
      when Feedjira::Parser::ITunesRSS
        build_from_itunes_rss(feed)
      when Feedjira::Parser::AtomYoutube
        build_from_atom_youtube(feed)
      end
    end

    def build_from_rss(feed)
      og = OpenGraph.new(feed.url)
      {
        title: feed.title,
        description: feed.description,
        site_url: feed.url,
        image_url: og.image
      }
    end

    def build_from_atom(feed)
      og = OpenGraph.new(feed.url)
      {
        title: feed.title,
        description: feed.description,
        site_url: feed.links.first,
        image_url: og.image
      }
    end

    def build_from_itunes_rss(feed)
      {
        title: feed.title,
        description: feed.description,
        site_url: feed.url,
        image_url: feed.itunes_image
      }
    end

    def build_from_atom_youtube(feed)
      og = OpenGraph.new(feed.url)
      {
        title: feed.title,
        description: og.description,
        site_url: feed.url,
        image_url: og.image
      }
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

    entries.sort_by(&:published).each do |entry|
      next if entry.title.blank?

      url = (entry.url || self.site_url).strip
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
      p [ "Saving item", entry.title, encoded_url, entry.published ] if item.new_record?

      item.update(parameters)
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
    image_url.presence || "https://placehold.jp/30/cccccc/ffffff/300x300.png?text=#{self.title}"
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

  def mark_items_checked!
    update!(last_items_checked_at: Time.current)
  end

  def set_check_interval!
    # 各期間内のアイテム数をカウント
    items_1_week = items.where('published_at > ?', 1.week.ago).count
    items_2_weeks = items.where('published_at > ?', 2.weeks.ago).count
    items_1_month = items.where('published_at > ?', 1.month.ago).count
    items_2_months = items.where('published_at > ?', 2.months.ago).count

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

  def notify_channel_change
    prefix = previous_changes.key?(:id) ? "New channel created" : "Channel updated"

    # check_interval_hoursとlast_items_checked_atの変更は通知しない
    ignored_fields = %w[check_interval_hours last_items_checked_at]
    relevant_changes = previous_changes.except(*ignored_fields)

    changed_fields = relevant_changes.keys.map { |field| "# #{field}\n- [Old] #{relevant_changes[field].first}\n- [New] #{relevant_changes[field].last}" }
    return if changed_fields.empty?

    content = [
      "[#{prefix}] #{title}",
      "```",
      changed_fields.join("\n\n"),
      "```"
    ].join("\n")

    DiscoPosterJob.perform_later(content: content)
  end
end
