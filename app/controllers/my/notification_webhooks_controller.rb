class My::NotificationWebhooksController < MyController
  def index
    @user = current_user
    @notification_webhooks = @user.notification_webhooks.order(id: :desc)
    @new_notification_webhook = @user.notification_webhooks.build

    @title = "My Notification Webhooks"
  end
end
