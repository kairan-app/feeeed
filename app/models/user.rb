class User < ApplicationRecord
  include UrlHttpValidator

  has_one_attached :avatar do |attachable|
    attachable.variant :display, resize_to_fill: [ 512, 512 ]
    attachable.variant :thumb, resize_to_fill: [ 128, 128 ]
    attachable.variant :small, resize_to_fill: [ 36, 36 ]
  end

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
  validates :icon_url, presence: true
  validates_url_http_format_of :icon_url

  def self.generate_default_name(email)
    local_part = email.split("@").first
    local_part.length >= 2 ? local_part : email.gsub("@", ".")
  end

  def admin?
    admin == true
  end

  def username_changed?
    email.split("@").first != name
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

  def not_pawed?(item)
    !pawed?(item)
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

  def avatar_url(variant: nil)
    if avatar.attached?
      # Use direct R2 URL if using R2 service
      if avatar.blob.service_name.to_s == "cloudflare_r2"
        if variant
          # Process variant and get direct CDN URL
          processed_variant = avatar.variant(variant).processed
          cdn_host = Rails.application.credentials.dig(:cloudflare_r2, :cdn_host)
          if cdn_host.present? && processed_variant.blob
            bucket = ENV["CLOUDFLARE_R2_BUCKET"] || Rails.application.credentials.dig(:cloudflare_r2, :bucket)
            "https://#{cdn_host}/#{bucket}/#{processed_variant.key}"
          else
            Rails.application.routes.url_helpers.rails_representation_url(
              avatar.variant(variant),
              only_path: false
            )
          end
        else
          # For original images, use CDN URL if configured, otherwise direct R2 URL
          cdn_host = Rails.application.credentials.dig(:cloudflare_r2, :cdn_host)
          if cdn_host.present?
            # Build CDN URL with bucket prefix
            key = avatar.blob.key
            bucket = ENV["CLOUDFLARE_R2_BUCKET"] || Rails.application.credentials.dig(:cloudflare_r2, :bucket)
            "https://#{cdn_host}/#{bucket}/#{key}"
          else
            avatar.blob.url(expires_in: 1.year, disposition: :inline, filename: avatar.blob.filename)
          end
        end
      else
        # Local storage - use Rails URLs
        if variant
          Rails.application.routes.url_helpers.rails_representation_url(
            avatar.variant(variant),
            only_path: true
          )
        else
          Rails.application.routes.url_helpers.rails_blob_url(avatar, only_path: true)
        end
      end
    else
      icon_url
    end
  end

  def unread_items_grouped_by_channel(range_days: 7, channel_group: nil)
    items = channel_group ? channel_group.items : subscribed_items

    items.
    includes(:channel, :pawprints).
    where("NOT EXISTS (SELECT 1 FROM pawprints WHERE pawprints.item_id = items.id AND pawprints.user_id = ?)", self.id).
    where("NOT EXISTS (SELECT 1 FROM item_skips WHERE item_skips.item_id = items.id AND item_skips.user_id = ?)", self.id).
    where("items.created_at > ?", range_days.days.ago).
    order("items.created_at DESC").
    group_by(&:channel).
    sort_by { |_, items| items.first.created_at }.
    reverse
  end

  def unread_items_for(channel, offset: 0, limit: 3, range_days: 7)
    channel.items.
    where("NOT EXISTS (SELECT 1 FROM pawprints WHERE pawprints.item_id = items.id AND pawprints.user_id = ?)", self.id).
    where("NOT EXISTS (SELECT 1 FROM item_skips WHERE item_skips.item_id = items.id AND item_skips.user_id = ?)", self.id).
    where("items.created_at > ?", range_days.days.ago).
    order("items.published_at DESC").
    offset(offset).
    limit(limit)
  end
end
