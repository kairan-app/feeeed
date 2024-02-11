module ChannelUserRelation
  extend ActiveSupport::Concern

  included do
    belongs_to :user
    belongs_to :channel

    validates :user_id, presence: true, uniqueness: { scope: :channel_id }
    validates :channel_id, presence: true, uniqueness: { scope: :user_id }
  end
end
