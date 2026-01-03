class SubscriptionTagging < ApplicationRecord
  belongs_to :subscription
  belongs_to :subscription_tag

  validates :subscription_id, uniqueness: { scope: :subscription_tag_id }
end
