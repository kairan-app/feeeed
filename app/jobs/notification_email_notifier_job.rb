class NotificationEmailNotifierJob < ApplicationJob
  def perform(ne_id)
    NotificationEmail.find(ne_id).notify
  end
end

