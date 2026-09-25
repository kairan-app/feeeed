class ItemCreationNotifierJob < ApplicationJob
  queue_as :disco

  def perform(item_id)
    item = Item.find(item_id)

    content = "New item saved"
    embeds = [ item.to_discord_embed ]

    DiscoPosterJob.perform_later(content:, embeds:, channel: :content_updates)
  end
end
