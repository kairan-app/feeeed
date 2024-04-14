class NotificationWebhook < ApplicationRecord
  include Rails.application.routes.url_helpers

  belongs_to :user

  validates :user_id, presence: true
  validates :url, presence: true, length: { maximum: 2083 }, format: { with: URI.regexp }
  validates :mode, presence: true

  enum mode: {
    my_subscribed_items: 0,
    my_pawprints: 1,
  }

  class << self
    def notify
      find_each(&:notify)
    end
  end

  def notify
    case mode
    when "my_subscribed_items"
      if URI(url).host == "hooks.slack.com" || url.ends_with?("/slack")
        notify_subscribed_items_to_slack
      else
        notify_subscribed_items
      end
    when "my_pawprints"
      notify_pawprints
    end
  end

  def notify_pawprints(since: nil)
    at = since || last_notified_at || 6.hours.ago
    pawprints = user.pawprints.where("created_at >= ?", at).order(:id)
    return if pawprints.empty?

    pawprints.to_a.each_slice(3).with_index { |sub_pawprints, index|
      content = "@#{user.name}'s recent pawprints 🐾" if index == 0
      embeds = sub_pawprints.map(&:to_embed)

      sleep 2
      Faraday.post(
        url, { content:, embeds: }.to_json, "Content-Type" => "application/json"
      )
    }

    touch(:last_notified_at)
  end

  def notify_subscribed_items(since: nil)
    at = since || last_notified_at || 6.hours.ago
    items = user.subscribed_items.where("items.created_at >= ?", at).order("items.id")
    return if items.empty?

    items.to_a.each_slice(3).with_index { |sub_items, index|
      content = "Recent items in @#{user.name}'s subscribed channels 📨" if index == 0
      embeds = sub_items.map(&:to_embed)

      sleep 2
      Faraday.post(
        url, { content:, embeds: }.to_json, "Content-Type" => "application/json"
      )
    }

    touch(:last_notified_at)
  end

  def notify_subscribed_items_to_slack(since: nil)
    at = since || last_notified_at || 6.hours.ago
    items = user.subscribed_items.preload(:channel).where("items.created_at >= ?", at)
    return if items.empty?

    items.group_by(&:channel).sort_by { |_, items| items.map(&:created_at).max }.each { |channel, sub_items|
      blocks = build_blocks(channel, sub_items)

      sleep 2
      Faraday.post(
        url, { blocks:, unfurl_links: false }.to_json, "Content-Type" => "application/json"
      )
    }

    touch(:last_notified_at)
  end

  def build_blocks(channel, items)
    items_blocks =
      items.sort_by(&:id).reverse.take(4).map { |item|
        {
          type: "section",
          text: {
            type: "mrkdwn",
            text: "<#{item.url}|#{item.title}>\n#{item.published_at.strftime("%Y-%m-%d %H:%M")}"
          },
          accessory: {
            type: "image",
            image_url: item.image_url,
            alt_text: item.title,
          }
        }
      }

    items_blocks.push(
       {
          type: "section",
          text: {
            type: "mrkdwn",
            text: "Check out more recent items in <%s|#{channel.title}>" % [
              Rails.application.credentials.google_auth_app.host + channel_path(channel)
            ]
          }
       }
    ) if items.size > 4

    [
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: "<#{channel.site_url}|#{channel.title}> 's recent items 📨"
        }
      },
      *items_blocks
    ]
  end
end
