class ChannelGroup < ApplicationRecord
  has_many :channel_groupings, dependent: :destroy
  has_many :channels, through: :channel_groupings

  validates :name, presence: true, length: { maximum: 64 }
end
