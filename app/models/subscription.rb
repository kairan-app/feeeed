class Subscription < ApplicationRecord
  include ChannelUserRelation

  has_many :subscription_taggings, dependent: :destroy
  has_many :subscription_tags, through: :subscription_taggings
end
