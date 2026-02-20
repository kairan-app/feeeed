class ChannelGroupWebhookDispatcherJob < ApplicationJob
  queue_as :default

  def perform
    ChannelGroupWebhook.notify
  end
end
