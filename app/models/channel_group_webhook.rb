class ChannelGroupWebhook < ApplicationRecord
  include SlackBlockBuilder
  include UrlHttpValidator

  belongs_to :user
  belongs_to :channel_group

  validates :user_id, presence: true
  validates :channel_group_id, presence: true
  validates :url, presence: true
  validates_url_http_format_of :url

  class << self
    def notify
      find_each { ChannelGroupWebhookNotifierJob.perform_later(_1.id) }
    end
  end

  def notify
    URI(url).host == "hooks.slack.com" ? notify_items_to_slack : notify_items_to_discord
  end

  def notify_items_to_discord(since: nil)
    at = since || last_notified_at || 6.hours.ago
    items = channel_group.items.where("items.created_at >= ?", at)
    return if items.empty?

    items.group_by(&:channel).sort_by { |_, items| items.map(&:created_at).max }.each do |channel, sub_items|
      content = "#{channel.title} 's new items 📨"
      embeds = sub_items.sort_by(&:id).last(3).map(&:to_discord_embed)

      sleep 2
      Faraday.post(
        url, { content:, embeds: }.to_json, "Content-Type": "application/json"
      )
    end

    touch(:last_notified_at)
  end

  def notify_items_to_slack(since: nil)
    at = since || last_notified_at || 6.hours.ago
    items = channel_group.items.where("items.created_at >= ?", at)
    return if items.empty?

    items.group_by(&:channel).sort_by { |_, items| items.map(&:created_at).max }.each { |channel, sub_items|
      blocks = build_slack_blocks(channel, sub_items)

      sleep 2
      Faraday.post(
        url, { blocks:, unfurl_links: false }.to_json, "Content-Type" => "application/json"
      )
    }

    touch(:last_notified_at)
  end
end
