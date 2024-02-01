class Channel < ApplicationRecord
  has_many :items, dependent: :destroy

  validates :title, presence: true, length: { maximum: 256 }
  validates :description, length: { maximum: 1024 }
  validates :site_url, presence: true, length: { maximum: 2083 }
  validates :feed_url, presence: true, length: { maximum: 2083 }, uniqueness: true
  validates :image_url, length: { maximum: 2083 }

  class << self
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
end
