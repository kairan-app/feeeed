class NotificationWebhookNotifierJob < ApplicationJob
  def perform(nw_id)
    NotificationWebhook.find(nw_id).notify
  end
end
