class ItemCreationNotifierJob < ApplicationJob
  queue_as :default

  def perform(item_id)
    item = Item.find(item_id)

    # 同じChannelの直近のItemが3分以内に通知されていたら通知しない
    prev_notified_at = item.channel.items.where.not(id: item.id).order(id: :desc).first&.created_at
    return if prev_notified_at && prev_notified_at > 3.minute.ago

    Faraday.post(
      ENV["DISCORD_WEBHOOK_URL"], {
        content: "[#{Rails.env}] New item created #{item.url}"
      }.to_json,
      "Content-Type" => "application/json"
    )
  end
end
