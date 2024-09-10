class ChannelGroupWebhookNotifierJob < ApplicationJob
  def perform(channel_group_webhook_id)
    ChannelGroupWebhook.find(channel_group_webhook_id).notify
  end
end
