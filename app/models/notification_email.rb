class NotificationEmail < ApplicationRecord
  belongs_to :user

  validates :user_id, presence: true
  validates :email, presence: true, length: { maximum: 254 }, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :mode, presence: true
  validates :verification_token, presence: true, uniqueness: true

  before_validation :set_verification_token
  after_create_commit { NotificationEmailVerificationJob.perform_later(self.id) }

  enum mode: {
    my_subscribed_items: 0,
    my_pawprints: 1,
  }

  scope :verified, -> { where.not(verified_at: nil) }

  def verify!
    update!(verified_at: Time.current)
  end

  def set_verification_token
    loop do
      token = SecureRandom.hex(16)
      next if NotificationEmail.exists?(verification_token: token)

      self.verification_token = token
      break
    end
  end
end
