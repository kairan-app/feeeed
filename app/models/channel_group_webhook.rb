class ChannelGroupWebhook < ApplicationRecord
  belongs_to :channel_group

  validates :channel_group_id, presence: true
  validates :url, presence: true, length: { maximum: 2083 }, format: { with: URI.regexp }

  def notify_items_to_discord(since: nil)
    at = since || last_notified_at || 6.hours.ago
    items = channel_group.items.where('created_at > ?', at).order(:created_at)
    return if items.empty?

    items.group_by(&:channel).sort_by { |_, items| items.map(&:created_at).max }.each do |channel, sub_items|
      content = "#{channel.title} 's new items 📨"
      embeds = sub_items.sort_by(&:id).reverse.take(3).map(&:to_discord_embed)

      sleep 2
      Faraday.post(
        url, { content:, embeds: }.to_json, "Content-Type": "application/json"
      )
    end
  end
end
