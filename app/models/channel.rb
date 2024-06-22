class Channel < ApplicationRecord
  include Rails.application.routes.url_helpers
  include Stripable
  include EmptyStringsAreAlignedToNil
  include ValidationErrorsNotifiable

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
  validates :site_url, length: { maximum: 2083 }
  validates :feed_url, presence: true, length: { maximum: 2083 }, uniqueness: true
  validates :image_url, length: { maximum: 2083 }

  strip_before_save :title, :description
  empty_strings_are_aligned_to_nil :description, :site_url, :image_url
  after_create_commit { ChannelItemsUpdaterJob.perform_later(channel_id: self.id, mode: :all) }

  scope :not_stopped, -> { where.missing(:stopper) }

  class << self
    def ransackable_attributes(auth_object = nil)
      %w[title description site_url feed_url]
    end

    def ransackable_associations(auth_object = nil)
      []
    end

    def fetch_and_save_items
      not_stopped.find_each { ChannelItemsUpdaterJob.perform_later(channel_id: _1.id) }
    end

    def add(url)
      feed_url = Feedbag.find(url).first

      return nil if feed_url.nil?

      save_from(feed_url)
    end

    def preview(url)
      feed_url = Feedbag.find(url).first
      return nil if feed_url.nil?

      feed = Feedjira.parse(Faraday.get(feed_url).body)
      feed.url = feed_url

      parameters =
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

      Channel.new(parameters.merge(feed_url: feed_url))
    end

    def save_from(feed_url)
      feed = Feedjira.parse(Faraday.get(feed_url).body)
      feed.url = feed_url

      parameters =
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

      channel = Channel.find_or_initialize_by(feed_url: feed_url)
      channel.update(parameters)
      channel
    end

    def build_from_rss(feed)
      og = OpenGraph.new(feed.url)
      {
        title: feed.title,
        description: feed.description,
        site_url: feed.url,
        image_url: og.image,
      }
    end

    def build_from_atom(feed)
      og = OpenGraph.new(feed.url)
      {
        title: feed.title,
        description: feed.description,
        site_url: feed.links.first,
        image_url: og.image,
      }
    end

    def build_from_itunes_rss(feed)
      {
        title: feed.title,
        description: feed.description,
        site_url: feed.url,
        image_url: feed.itunes_image,
      }
    end

    def build_from_atom_youtube(feed)
      og = OpenGraph.new(feed.url)
      {
        title: feed.title,
        description: og.description,
        site_url: feed.url,
        image_url: og.image,
      }
    end

    def similar_to(channel)
      Channel.ransack({
        g: { "0" => { m: "or", title_cont: channel.title, site_url_cont: channel.site_url }}
      }).result
    end
  end

  def fetch_and_save_items(mode = :only_new)
    feed = Feedjira.parse(Faraday.get(feed_url).body)

    entries =
      if mode == :only_new
        feed.entries.reject { self.items.exists?(guid: _1.entry_id) }
      else
        feed.entries
      end

    entries.sort_by(&:published).each do |entry|
      sleep 2

      p ["Fetching", entry.published, entry.title, entry.url]
      next if entry.title.blank?

      url = (entry.url || self.site_url).strip
      encoded_url = url.chars.map { |c| c.bytesize > 1 ? URI.encode_www_form_component(c) : c }.join

      guid = entry.entry_id || entry.url

      image_url =
        if guid.start_with?("yt:video:")
          "https://img.youtube.com/vi/%s/maxresdefault.jpg" % guid.sub("yt:video:", "")
        else
          OpenGraph.new(encoded_url).image
        end

      parameters = {
        guid: guid,
        title: entry.title,
        url: encoded_url,
        image_url: image_url,
        published_at: entry.published,
        data: entry.to_h,
      }
      self.items.find_or_initialize_by(guid: guid).update(parameters)
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
      url: channel_url(self),
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
end
