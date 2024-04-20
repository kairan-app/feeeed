class Pawprint < ApplicationRecord
  belongs_to :user
  belongs_to :item

  validates :user_id, presence: true, uniqueness: { scope: :item_id }
  validates :item_id, presence: true, uniqueness: { scope: :user_id }
  validates :memo, length: { maximum: 300 }

  after_create_commit { PawprintCreationNotifierJob.perform_later(self.id) }

  def to_discord_embed
    channel = item.channel
    {
      author: { name: [channel.title, URI.parse(item.url).host].join(" | "), url: channel.site_url },
      title: item.title,
      description: memo.present? ? "💬 #{memo}" : nil,
      url: item.url,
      thumbnail: { url: item.image_url },
      timestamp: self.created_at.iso8601,
    }
  end
end
