class NotificationWebhook < ApplicationRecord
  belongs_to :user

  validates :user_id, presence: true
  validates :url, presence: true, length: { maximum: 2083 }

  def notify_reactions(since: nil)
    at = since || reactions_last_notified_at || 6.hours.ago
    reactions = user.reactions.where("created_at >= ?", at).order(id: :desc)
    return if reactions.empty?

    content = "@#{user.name}'s recent pawprints 🐾"

    reactions.find_in_batches(batch_size: 10) { |sub_reactions|
      embeds =
        sub_reactions.map { |reaction|
          {
            title: [reaction.item.title, reaction.item.channel.title].join(" | "),
            description: reaction.memo.present? ? "💬 #{reaction.memo}" : nil,
            url: reaction.item.url,
            thumbnail: { url: reaction.item.image_url },
          }
        }

      sleep 2
      Faraday.post(
        url, { content:, embeds: }.to_json, "Content-Type" => "application/json"
      )
    }

    update_reactions_last_notified_at
  end

  def reactions_last_notified_at
    value = Rails.cache.read(cache_key(:reactions_last_notified_at))
    return if value.nil?

    Time.zone.at(value)
  end

  def update_reactions_last_notified_at
    Rails.cache.write(cache_key(:reactions_last_notified_at), Time.current.to_i)
  end

  def cache_key(suffix)
    "notification_webhook/#{id}/#{suffix}"
  end
end
