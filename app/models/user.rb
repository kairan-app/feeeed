class User < ApplicationRecord
  has_many :ownerships, dependent: :destroy
  has_many :owned_channels, through: :ownerships, source: :channel
  has_many :memberships, dependent: :destroy
  has_many :joined_channel_groups, through: :memberships, source: :channel_group
  has_many :subscriptions, dependent: :destroy
  has_many :subscribed_channels, through: :subscriptions, source: :channel
  has_many :subscribed_items, through: :subscribed_channels, source: :items
  has_many :channel_groups, foreign_key: :owner_id, dependent: :destroy
  has_many :pawprints, dependent: :destroy
  has_many :pawed_items, through: :pawprints, source: :item
  has_many :item_skips, dependent: :destroy
  has_many :notification_webhooks, dependent: :destroy
  has_many :notification_emails, dependent: :destroy
  has_many :channel_group_webhooks, dependent: :destroy

  validates :name, presence: true, uniqueness: true, length: { in: 2..30 }
  validates :email, presence: true, length: { maximum: 254 }
  validates :icon_url, presence: true, length: { maximum: 2083 }

  def username_changed?
    email.split('@').first != name
  end

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

  def join(channel_group)
    memberships.create(channel_group: channel_group)
  end

  def leave(channel_group)
    memberships.find_by(channel_group: channel_group)&.destroy
  end

  def skip(item)
    item_skips.create(item: item)
  end

  def unskip(item)
    item_skips.find_by(item: item).destroy
  end

  def own_and_joined_channel_groups
    ChannelGroup.where(id: joined_channel_groups.pluck(:id)).or(ChannelGroup.where(owner_id: self.id))
  end

  def unread_items_grouped_by_channel(range_days: 7, channel_group: nil)
    items = channel_group ? channel_group.items : subscribed_items

    items.
    preload(:channel).
    where("NOT EXISTS (SELECT 1 FROM pawprints WHERE pawprints.item_id = items.id AND pawprints.user_id = ?)", self.id).
    where("NOT EXISTS (SELECT 1 FROM item_skips WHERE item_skips.item_id = items.id AND item_skips.user_id = ?)", self.id).
    where("items.created_at > ?", range_days.days.ago).
    group_by(&:channel).
    sort_by { |_, items| items.map(&:created_at).max }.
    reverse
  end
end
