class Reaction < ApplicationRecord
  belongs_to :user
  belongs_to :item

  validates :user_id, presence: true, uniqueness: { scope: :item_id }
  validates :item_id, presence: true, uniqueness: { scope: :user_id }
  validates :memo, length: { maximum: 300 }

  after_create_commit { ReactionCreationNotifierJob.perform_later(self.id) }
end
