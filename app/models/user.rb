class User < ApplicationRecord
  has_many :ownerships, dependent: :destroy
  has_many :owned_channels, through: :ownerships, source: :channel
  has_many :subscriptions, dependent: :destroy
  has_many :subscribed_channels, through: :subscriptions, source: :channel
  has_many :subscribed_items, through: :subscribed_channels, source: :items
  has_many :pawprints, dependent: :destroy
  has_many :pawed_items, through: :pawprints, source: :item
  has_many :item_skips, dependent: :destroy
  has_many :notification_webhooks, dependent: :destroy

  validates :name, presence: true, uniqueness: true, length: { in: 2..15 }
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

  def paw(item, memo:)
    pawprint = pawprints.find_or_initialize_by(item: item)
    pawprint.update(memo: memo.presence)
    pawprint
  end

  def unpaw(item)
    pawprints.find_by(item: item).destroy
  end

  def pawed?(item)
    pawed_items.include?(item)
  end

  def skip(item)
    item_skips.create(item: item)
  end

  def unskip(item)
    item_skips.find_by(item: item).destroy
  end
end
