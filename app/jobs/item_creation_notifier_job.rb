class ItemCreationNotifierJob < ApplicationJob
  queue_as :default

  def perform(item_id)
    item = Item.find(item_id)

    Faraday.post(
      ENV["DISCORD_WEBHOOK_URL"], {
        content: "New item created: #{item.url}"
      }.to_json,
      "Content-Type" => "application/json"
    )
  end
end
