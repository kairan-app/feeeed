class Channel < ApplicationRecord
  has_many :items, dependent: :destroy

  validates :title, presence: true, length: { maximum: 100 }
  validates :description, length: { maximum: 255 }
  validates :site_link, presence: true, length: { maximum: 255 }
  validates :feed_link, presence: true, length: { maximum: 255 }, uniqueness: true
  validates :image_url, length: { maximum: 255 }

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

      Channel.find_or_initialize_by(feed_link: feed_url).update(parameters)
    end

    def build_from_rss(feed)
      p "save_from_rss"
      og = OpenGraph.new(feed.url)
      {
        title: feed.title,
        description: feed.description,
        site_link: feed.url,
        image_url: og.images.first,
      }
    end

    def build_from_atom(feed)
      p "save_from_atom"
      og = OpenGraph.new(feed.url)
      {
        title: feed.title,
        description: feed.description,
        site_link: feed.links.first,
        image_url: og.images.first,
      }
    end

    def build_from_itunes_rss(feed)
      p "save_from_itunes_rss"
      {
        title: feed.title,
        description: feed.description,
        site_link: feed.url,
        image_url: feed.itunes_image,
      }
    end

    def build_from_atom_youtube(feed)
      p "save_from_atom_youtube"
      {
        title: feed.title,
        site_link: feed.url,
      }
    end
  end
end
