class NotificationWebhook < ApplicationRecord
  belongs_to :user

  validates :user_id, presence: true
  validates :url, presence: true, length: { maximum: 2083 }
end
