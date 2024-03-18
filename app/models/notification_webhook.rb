class NotificationWebhook < ApplicationRecord
  belongs_to :user

  validates :user_id, presence: true
  validates :url, presence: true, length: { maximum: 2083 }

  class << self
    def notify
      find_each { _1.notify_pawprints }
    end
  end

  def notify_pawprints(since: nil)
    at = since || last_notified_at || 6.hours.ago
    pawprints = user.pawprints.where("created_at >= ?", at).order(id: :desc)
    return if pawprints.empty?

    content = "@#{user.name}'s recent pawprints 🐾"

    pawprints.find_in_batches(batch_size: 10) { |sub_pawprints|
      embeds = sub_pawprints.map(&:to_embed)

      sleep 2
      Faraday.post(
        url, { content:, embeds: }.to_json, "Content-Type" => "application/json"
      )
    }

    touch(:last_notified_at)
  end
end
