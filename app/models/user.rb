class User < ApplicationRecord
  has_many :ownerships, dependent: :destroy
  has_many :owned_channels, through: :ownerships, source: :channel
  has_many :subscriptions, dependent: :destroy
  has_many :subscribed_channels, through: :subscriptions, source: :channel
  has_many :subscribed_items, through: :subscribed_channels, source: :items

  validates :name, presence: true, length: { in: 2..15 }
  validates :email, presence: true, length: { maximum: 254 }
  validates :icon_url, presence: true, length: { maximum: 2083 }

  def add_channel(channel)
    owned_channels << channel
  end

  def remove_channel(channel)
    owned_channels.delete(channel)
  end

  def subscribe(channel)
    subscribed_channels << channel
  end

  def unsubscribe(channel)
    subscribed_channels.delete(channel)
  end
end
