require "digest"
require "securerandom"

class AppPassword < ApplicationRecord
  TOKEN_PREFIX = "rururu_"

  belongs_to :user

  validates :name, presence: true, length: { maximum: 50 }

  scope :active, -> { where(revoked_at: nil) }
  scope :revoked, -> { where.not(revoked_at: nil) }

  def revoked?
    revoked_at.present?
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def self.issue!(user:, name:)
    plain = TOKEN_PREFIX + SecureRandom.urlsafe_base64(32)
    record = create!(
      user: user,
      name: name,
      token_digest: digest(plain),
      token_last_4: plain.last(4),
    )
    [ plain, record ]
  end

  def self.authenticate(plain)
    return nil if plain.blank?
    record = active.find_by(token_digest: digest(plain))
    return nil unless record
    record.touch(:last_used_at)
    record.user
  end

  def self.digest(plain)
    Digest::SHA256.hexdigest(plain)
  end
end
