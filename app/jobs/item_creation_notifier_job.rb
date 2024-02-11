class ItemCreationNotifierJob < ApplicationJob
  queue_as :default

  def perform(item_id)
    webhook_url = ENV["DISCORD_WEBHOOK_URL"]
    return if webhook_url.nil?

    item = Item.find(item_id)
    channel = item.channel

    return unless should_notify?(item)

    Faraday.post(
      webhook_url, {
        content: "[#{Rails.env}] New item created #{item.url}"
      }.to_json,
      "Content-Type" => "application/json"
    )
  end

  def should_notify?(item)
    channel = item.channel

    # Channel作成から一定以上の時間が経過しているものは、新着検知されたItemとみなして通知する
    return true if item.channel.created_at < 1.hour.ago

    # Channel作成時に一括でItemが保存されるときは、最新のItemをひとつだけ通知する
    feed = Feedjira.parse(Faraday.get(channel.feed_url).body)
    return true if item.guid == feed.entries.sort_by(&:published).last.entry_id

    false
  end
end
