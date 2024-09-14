class ChannelItemsUpdaterJob < ApplicationJob
  def perform(channel_id:, mode: :only_recent)
    channel = Channel.find(channel_id)
    channel.fetch_and_save_items(mode)
  end
end
