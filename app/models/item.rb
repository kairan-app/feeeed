class Item < ApplicationRecord
  belongs_to :channel

  validates :channel_id, presence: true
  validates :guid, presence: true, length: { maximum: 256 }, uniqueness: { scope: :channel_id }
  validates :title, presence: true, length: { maximum: 256 }
  validates :url, presence: true, length: { maximum: 2083 }
  validates :image_url, length: { maximum: 2083 }
  validates :published_at, presence: true

  after_create_commit { ItemCreationNotifierJob.perform_later(self.id) }
end
