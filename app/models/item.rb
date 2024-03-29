class Item < ApplicationRecord
  belongs_to :channel
  has_many :pawprints, dependent: :destroy
  has_many :pawed_users, through: :pawprints, source: :user

  validates :channel_id, presence: true
  validates :guid, presence: true, length: { maximum: 256 }, uniqueness: { scope: :channel_id }
  validates :title, presence: true, length: { maximum: 256 }
  validates :url, presence: true, length: { maximum: 2083 }
  validates :image_url, length: { maximum: 2083 }
  validates :published_at, presence: true

  after_create_commit { ItemCreationNotifierJob.perform_later(self.id) }

  def image_url_or_placeholder
    image_url.presence || "https://placehold.jp/30/cccccc/ffffff/270x180.png?text=#{self.title}"
  end

  def to_embed
    {
      author: { name: [channel.title, URI.parse(self.url).host].join(" | "), url: channel.site_url },
      title: self.title,
      url: self.url,
      thumbnail: { url: self.image_url },
      timestamp: self.published_at.iso8601,
    }
  end
end
