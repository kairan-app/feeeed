class Channel < ApplicationRecord
  has_many :items, dependent: :destroy

  validates :title, presence: true, length: { maximum: 100 }
  validates :description, length: { maximum: 255 }
  validates :site_link, presence: true, length: { maximum: 255 }
  validates :feed_link, presence: true, length: { maximum: 255 }, uniqueness: true
  validates :image_url, presence: true, length: { maximum: 255 }

  class << self
    def add(url)
      feed_urls = Feedbag.find(url)

      return nil if feed_urls.empty?

      feed = Feedjira.parse(Faraday.get(feed_urls.first).body)
      save_from(feed)
    end

    def save_from(feed)
      case feed
      when Feedjira::Parser::RSS
        save_from_rss(feed)
      when Feedjira::Parser::Atom
        save_from_atom(feed)
      when Feedjira::Parser::ITunesRSS
        save_from_itunes_rss(feed)
      when Feedjira::Parser::AtomYoutube
        save_from_atom_youtube(feed)
      end
    end
  end
end
