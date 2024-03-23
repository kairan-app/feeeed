class My::NotificationWebhooksController < MyController
  def index
    @user = current_user
    @notification_webhooks = @user.notification_webhooks.order(id: :desc)

    @title = "My Notification Webhooks"
  end
end
