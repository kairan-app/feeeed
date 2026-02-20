class NotificationEmailDispatcherJob < ApplicationJob
  queue_as :default

  def perform
    NotificationEmail.notify
  end
end
