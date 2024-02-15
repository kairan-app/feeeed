class ChannelItemsUpdaterJob < ApplicationJob
  sidekiq_options retry: 2

  def perform(channel_id:, mode: :only_new)
    channel = Channel.find(channel_id)
    channel.fetch_and_save_items(mode)
  end
end
