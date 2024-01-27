class Item < ApplicationRecord
  belongs_to :channel

  validates :channel_id, presence: true
  validates :guid, presence: true, length: { maximum: 255 }, uniqueness: { scope: :channel_id }
  validates :title, presence: true, length: { maximum: 100 }
  validates :link, presence: true, length: { maximum: 255 }
  validates :image_url, length: { maximum: 255 }
end
