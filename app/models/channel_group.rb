class ChannelGroup < ApplicationRecord
  has_many :channel_groupings, dependent: :destroy
  has_many :channels, through: :channel_groupings
  has_many :items, through: :channels
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :channel_group_webhooks, dependent: :destroy

  validates :name, presence: true, length: { maximum: 64 }
end
