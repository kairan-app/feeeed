class My::GuidesController < MyController
  def show
    @channel_subscribed = current_user.subscribed_channels.count > 0
    @channel_owned = current_user.owned_channels.count > 0
    @item_pawed = current_user.pawprints.count > 0
    @notification_webhook_created = current_user.notification_webhooks.count > 0
    @notification_email_created = current_user.notification_emails.count > 0

    @title = "Guides"
  end
end
