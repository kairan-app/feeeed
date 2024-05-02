class NotificationEmail < ApplicationRecord
  belongs_to :user

  validates :user_id, presence: true
  validates :email, presence: true, length: { maximum: 254 }, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :mode, presence: true
  validates :verification_token, presence: true, uniqueness: true

  before_validation :set_verification_token
  after_create_commit { NotificationEmailMailer.please_verify(self).deliver_later }

  scope :only_verified, -> { where.not(verified_at: nil) }

  enum mode: {
    my_subscribed_items: 0,
    my_pawprints: 1,
  }

  class << self
    def notify
      only_verified.find_each { NotificationEmailNotifierJob.perform_later(_1.id) }
    end
  end

  def notify
    case mode
    when "my_subscribed_items"
      notify_subscribed_items
    when "my_pawprints"
      notify_pawprints
    end
  end

  def notify_pawprints(since: nil)
    at = since || last_notified_at || 6.hours.ago
    pawprints = user.pawprints.where("created_at >= ?", at).to_a
    return if pawprints.empty?

    NotificationEmailMailer.pawprints(notification_email: self, pawprints:).deliver_later
    touch(:last_notified_at)
  end

  def notify_subscribed_items(since: nil)
    at = since || last_notified_at || 6.hours.ago
    items = user.subscribed_items.preload(:channel).where("items.created_at >= ?", at).order("items.id")

    return if items.empty?

    channels = items.map(&:channel).uniq

    subject =
      if channels.count == 1
        "New item from #{channels.first.title}"
      elsif channels.count == 2
        titles = channels.shuffle.map(&:title).join("、")
        "New items from #{titles}"
      else
        titles = channels.sample(2).map(&:title).join("、")
        "New items from #{titles} and more"
      end

    channel_and_items = items.group_by(&:channel).sort_by { |_, items| items.map(&:created_at).max }

    NotificationEmailMailer.subscribed_items(notification_email: self, channel_and_items:, subject:).deliver_later
    touch(:last_notified_at)
  end

  def verified?
    !verified_at.nil?
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
