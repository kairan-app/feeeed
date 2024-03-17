class ItemCreationNotifierJob < ApplicationJob
  def perform(item_id)
    webhook_url = ENV["DISCORD_WEBHOOK_URL"]
    return if webhook_url.nil?

    item = Item.find(item_id)

    return unless should_notify?(item)

    content = "[#{Rails.env}] New item saved"
    p item.to_embed
    embeds = [item.to_embed]

    Faraday.post(
      webhook_url, { content: , embeds: }.to_json, "Content-Type" => "application/json"
    )
  end

  def should_notify?(item)
    # 新しい方から見て3件以内のItemのみ通知する
    feed = Feedjira.parse(Faraday.get(item.channel.feed_url).body)
    return true if item.guid.in?(feed.entries.sort_by(&:published).reverse.take(2).map(&:entry_id))

    false
  end
end
