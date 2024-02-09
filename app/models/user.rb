class User < ApplicationRecord
  has_many :ownerships, dependent: :destroy
  has_many :owned_channels, through: :ownerships, source: :channel

  validates :name, presence: true, length: { in: 2..15 }
  validates :email, presence: true, length: { maximum: 254 }
  validates :icon_url, presence: true, length: { maximum: 2083 }
end
