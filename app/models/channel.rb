class Channel < ApplicationRecord
  has_many :items, dependent: :destroy
  has_many :ownerships, dependent: :destroy
  has_many :owners, through: :ownerships, source: :user

  validates :title, presence: true, length: { maximum: 256 }
  validates :description, length: { maximum: 1024 }
  validates :site_url, presence: true, length: { maximum: 2083 }
  validates :feed_url, presence: true, length: { maximum: 2083 }, uniqueness: true
  validates :image_url, length: { maximum: 2083 }

  after_create_commit { ChannelItemsUpdaterJob.perform_later(channel_id: self.id, mode: :all) }

  class << self
    def fetch_and_save_items
      find_each { ChannelItemsUpdaterJob.perform_later(channel_id: _1.id) }
    end

    def add(url)
      feed_url = Feedbag.find(url).first

      return nil if feed_url.nil?

      save_from(feed_url)
    end

    def save_from(feed_url)
      feed = Feedjira.parse(Faraday.get(feed_url).body)

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

      Channel.find_or_initialize_by(feed_url: feed_url).update(parameters)
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
      p ["Fetching", entry.published, entry.title, entry.url]

      sleep 3

      og = OpenGraph.new(entry.url)
      parameters = {
        guid: entry.entry_id,
        title: entry.title,
        url: entry.url,
        image_url: og.image,
        published_at: entry.published,
      }
      self.items.find_or_initialize_by(guid: parameters[:guid]).update(parameters)
    end
  end

  def owned_by?(user)
    self.owners.exists?(id: user.id)
  end
end
