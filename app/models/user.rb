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
  has_many :notification_emails, dependent: :destroy

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

  def skip(item)
    item_skips.create(item: item)
  end

  def unskip(item)
    item_skips.find_by(item: item).destroy
  end

  def unread_items_grouped_by_channel(range_days: 7, mode: :all)
    self.
    subscribed_items.
    preload(:channel).
    where("NOT EXISTS (SELECT 1 FROM pawprints WHERE pawprints.item_id = items.id AND pawprints.user_id = ?)", self.id).
    where("NOT EXISTS (SELECT 1 FROM item_skips WHERE item_skips.item_id = items.id AND item_skips.user_id = ?)", self.id).
    where("items.created_at > ?", range_days.days.ago).
    select {
      if mode == :audio
        _1.audio_enclosure_url.present?
      elsif mode == :video
        _1.video_enclosure_url.present?
      elsif mode == :text
        _1.audio_enclosure_url.nil? && _1.video_enclosure_url.nil?
      else
        true
      end
    }.
    group_by(&:channel).
    sort_by { |_, items| items.map(&:created_at).max }.
    reverse
  end
end
