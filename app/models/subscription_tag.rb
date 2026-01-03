class SubscriptionTag < ApplicationRecord
  belongs_to :user
  has_many :subscription_taggings, dependent: :destroy
  has_many :subscriptions, through: :subscription_taggings

  validates :name, presence: true, length: { maximum: 32 }
  validates :name, uniqueness: { scope: :user_id }
  validates :position, presence: true

  scope :ordered, -> { order(:position) }
end
