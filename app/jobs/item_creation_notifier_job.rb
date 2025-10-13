class ItemCreationNotifierJob < ApplicationJob
  queue_as :disco

  def perform(item_id)
    item = Item.find(item_id)

    return unless should_notify?(item)

    content = "New item saved"
    embeds = [ item.to_discord_embed ]

    DiscoPosterJob.perform_later(content:, embeds:, channel: :content_updates)
  end

  def should_notify?(item)
    sleep 1
    # 新しい方から見て2件以内のItemのみ通知する
    feed = Feedjira.parse(Httpc.get(item.channel.feed_url))
    return true if item.guid.in?(feed.entries.sort_by(&:published).reverse.take(2).map { [ _1.entry_id, _1.url ] }.flatten)

    false
  end
end
