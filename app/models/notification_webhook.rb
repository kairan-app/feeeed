class NotificationWebhook < ApplicationRecord
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
      find_each { NotificationWebhookNotifierJob.perform_later(_1.id) }
    end
  end

  def notify
    is_slack = URI(url).host == "hooks.slack.com"

    case mode
    when "my_subscribed_items"
      is_slack ? notify_subscribed_items_to_slack : notify_subscribed_items_to_discord
    when "my_pawprints"
      is_slack ? notify_pawprints_to_slack : notify_pawprints_to_discord
    end
  end

  def notify_pawprints_to_discord(since: nil)
    at = since || last_notified_at || 6.hours.ago
    pawprints = user.pawprints.where("created_at >= ?", at).order(:id)
    return if pawprints.empty?

    DiscoPosterJob.perform_later(content:
      "NotificationWebhook performed (id: #{id}, user: @#{user.name}, mode: pawprints_to_discord, #{pawprints.count} pawprints)"
    )

    pawprints.to_a.each_slice(3).with_index { |sub_pawprints, index|
      content = "@#{user.name}'s recent pawprints 🐾" if index == 0
      embeds = sub_pawprints.map(&:to_discord_embed)

      sleep 2
      Faraday.post(
        url, { content:, embeds: }.to_json, "Content-Type" => "application/json"
      )
    }

    touch(:last_notified_at)
  end

  def notify_pawprints_to_slack(since: nil)
    at = since || last_notified_at || 6.hours.ago
    pawprints = user.pawprints.where("created_at >= ?", at).order(:id)
    return if pawprints.empty?

    DiscoPosterJob.perform_later(content:
      "NotificationWebhook performed (id: #{id}, user: @#{user.name}, mode: pawprints_to_slack, #{pawprints.count} pawprints)"
    )

    pawprints.to_a.each_slice(5).with_index { |sub_pawprints, index|
      blocks = sub_pawprints.map(&:to_slack_block).flatten
      blocks.unshift({
        type: "header",
        text: {
          type: "plain_text",
          text: "@#{user.name}'s recent pawprints 🐾",
        }
      }) if index == 0

      sleep 2
      Faraday.post(
        url, { blocks:, unfurl_links: false }.to_json, "Content-Type" => "application/json"
      )
    }

    touch(:last_notified_at)
  end

  def notify_subscribed_items_to_discord(since: nil)
    at = since || last_notified_at || 6.hours.ago
    items = user.subscribed_items.where("items.created_at >= ?", at).order("items.id")
    return if items.empty?

    DiscoPosterJob.perform_later(content:
      "NotificationWebhook performed (id: #{id}, user: @#{user.name}, mode: subscribed_items_to_discord, #{items.count} items)"
    )

    items.group_by(&:channel).sort_by { |_, items| items.map(&:created_at).max }.each { |channel, sub_items|
      content = "#{channel.title} 's recent items 📨"
      embeds = sub_items.sort_by(&:id).reverse.take(4).map(&:to_discord_embed)
      embeds.push(channel.to_discord_more_embed) if sub_items.size > 4

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

    DiscoPosterJob.perform_later(content:
      "NotificationWebhook performed (id: #{id}, user: @#{user.name}, mode: subscribed_items_to_slack, #{items.count} items)"
    )

    items.group_by(&:channel).sort_by { |_, items| items.map(&:created_at).max }.each { |channel, sub_items|
      blocks = build_slack_blocks(channel, sub_items)

      sleep 2
      Faraday.post(
        url, { blocks:, unfurl_links: false }.to_json, "Content-Type" => "application/json"
      )
    }

    touch(:last_notified_at)
  end

  def build_slack_blocks(channel, items)
    items_blocks = items.sort_by(&:id).reverse.take(4).map(&:to_slack_block)
    items_blocks.push(channel.to_slack_more_block) if items.size > 4

    [channel.to_slack_header_block, *items_blocks]
  end
end
