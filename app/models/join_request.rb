class JoinRequest < ApplicationRecord
  belongs_to :approved_by, class_name: "User", optional: true

  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :comment, length: { maximum: 256 }

  scope :pending, -> { where(approved_at: nil) }
  scope :approved, -> { where.not(approved_at: nil) }
  scope :recent, -> { order(created_at: :desc) }

  def approve!(admin_user)
    update!(
      approved_by: admin_user,
      approved_at: Time.current
    )
  end

  def approved?
    approved_at.present?
  end

  def pending?
    approved_at.nil?
  end
end
