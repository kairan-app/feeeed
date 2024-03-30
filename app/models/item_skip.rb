class ItemSkip < ApplicationRecord
  belongs_to :item
  belongs_to :user

  validates :item_id, presence: true, uniqueness: { scope: :user_id }
  validates :user_id, presence: true
end
