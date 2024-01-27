class Channel < ApplicationRecord
  validates :title, presence: true, length: { maximum: 100 }
  validates :description, length: { maximum: 255 }
  validates :site_link, presence: true, length: { maximum: 255 }
  validates :feed_link, presence: true, length: { maximum: 255 }, uniqueness: true
  validates :image_url, presence: true, length: { maximum: 255 }
end
