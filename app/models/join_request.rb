class JoinRequest < ApplicationRecord
  belongs_to :approved_by, class_name: "User", optional: true

  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :comment, length: { maximum: 256 }

  scope :pending, -> { where(approved_at: nil) }
  scope :approved, -> { where.not(approved_at: nil) }

  def approve_by(user)
    result = update(
      approved_by: user,
      approved_at: Time.current
    )

    if result
      JoinRequestMailer.welcome(self).deliver_later
      DiscoPosterJob.perform_later(
        content: "✅ #{email}を承認しました (by @#{user.name})",
        channel: :admin
      )
    end

    result
  end

  def approved?
    approved_at.present?
  end

  def pending?
    approved_at.nil?
  end
end
