class My::NotificationSettingsController < MyController
  def index
    @user = current_user
    @notification_webhooks = @user.notification_webhooks.order(id: :desc)
    @new_notification_webhook = @user.notification_webhooks.build
    @notification_emails = @user.notification_emails.order(id: :desc)
    @new_notification_email = @user.notification_emails.build
    @channel_group_webhooks = @user.channel_group_webhooks.order(id: :desc)
    @new_channel_group_webhook = @user.channel_group_webhooks.build

    @title = "My Notification Settings"
  end
end
