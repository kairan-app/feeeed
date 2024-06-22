class ChannelGroupWebhook < ApplicationRecord
  belongs_to :channel_group

  validates :channel_group_id, presence: true
  validates :url, presence: true, length: { maximum: 2083 }, format: { with: URI.regexp }
end
