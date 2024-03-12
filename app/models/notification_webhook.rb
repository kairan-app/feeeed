class NotificationWebhook < ApplicationRecord
  belongs_to :user

  validates :user_id, presence: true
  validates :url, presence: true, length: { maximum: 2083 }

  def notify_reactions(recent: 24.hours.ago)
    reactions = user.reactions.where("created_at > ?", recent)
    return if reactions.empty?

    reactions_text =
      reactions.map { |reaction|
        string = "- #{reaction.item.title} | #{reaction.item.channel.title}\n  - #{reaction.item.url}"
        string += "\n  - 💬 #{reaction.memo}" if reaction.memo.present?
        string
      }.join("\n")

    message = <<~MESSAGE
      @#{user.name}'s recent pawprints 🐾
      #{reactions_text}
    MESSAGE

    # https://discord.com/developers/docs/resources/channel#message-object-message-flags
    flags = "01000000100".to_i(2)

    Faraday.post(
      url, { content: message, flags: flags }.to_json, "Content-Type" => "application/json"
    )
  end
end
