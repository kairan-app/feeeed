class NotificationWebhookDispatcherJob < ApplicationJob
  queue_as :default

  def perform
    NotificationWebhook.notify
  end
end
