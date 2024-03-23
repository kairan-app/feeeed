class NotificationWebhook < ApplicationRecord
  belongs_to :user

  validates :user_id, presence: true
  validates :url, presence: true, length: { maximum: 2083 }
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
      notify_subscribed_items
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
end
