class ChannelItemsUpdaterJob < ApplicationJob
  def perform(channel_id:, mode: :only_non_existing)
    channel = Channel.find(channel_id)
    channel.update_info
    channel.fetch_and_save_items(mode)
    channel.mark_items_checked!
  end
end
