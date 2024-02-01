class User < ApplicationRecord
  validates :name, presence: true, length: { in: 2..15 }
  validates :email, presence: true, length: { maximum: 254 }
  validates :icon_url, presence: true, length: { maximum: 2083 }
end
