class ChannelGrouping < ApplicationRecord
  belongs_to :channel
  belongs_to :channel_group

  validates :channel_id, uniqueness: { scope: :channel_group_id }
end
