class NotificationWebhook < ApplicationRecord
  belongs_to :user

  validates :user_id, presence: true
  validates :url, presence: true, length: { maximum: 2083 }

  class << self
    def notify
      find_each { _1.notify_reactions }
    end
  end

  def notify_reactions(since: nil)
    at = since || last_notified_at || 6.hours.ago
    reactions = user.reactions.where("created_at >= ?", at).order(id: :desc)
    return if reactions.empty?

    content = "@#{user.name}'s recent pawprints 🐾"

    reactions.find_in_batches(batch_size: 10) { |sub_reactions|
      embeds = sub_reactions.map(&:to_embed)

      sleep 2
      Faraday.post(
        url, { content:, embeds: }.to_json, "Content-Type" => "application/json"
      )
    }

    touch(:last_notified_at)
  end
end
