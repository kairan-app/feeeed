class ItemCreationNotifierJob < ApplicationJob
  queue_as :disco

  def perform(item_id)
    # ジョブが動く前にアイテムが消えていたら、通知しなくてよい
    item = Item.find_by(id: item_id)
    return if item.nil?

    content = "New item saved"
    embeds = [ item.to_discord_embed ]

    DiscoPosterJob.perform_later(content:, embeds:, channel: :content_updates)
  end
end
