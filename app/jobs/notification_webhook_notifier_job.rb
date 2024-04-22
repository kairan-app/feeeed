class NotificationWebhookNotifierJob < ApplicationJob
  def perform(nw_id)
    nw = NotificationWebhook.find(nw_id)
    nw.notify
  end
end
