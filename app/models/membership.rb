class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :channel_group

  validates :user_id, presence: true, uniqueness: { scope: :channel_group_id }
  validates :channel_group_id, presence: true
end
