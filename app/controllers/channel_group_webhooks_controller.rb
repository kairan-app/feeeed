class ChannelGroupWebhooksController < ApplicationController
  def create
    channel_group_webhook = current_user.channel_group_webhooks.build(channel_group_webhook_params)

    if channel_group_webhook.save
      redirect_to my_notification_settings_path, notice: "Channel group webhook was successfully created."
    else
      redirect_to my_notification_settings_path, alert: "Failed to create channel group webhook."
    end
  end

  def destroy
    channel_group_webhook = current_user.channel_group_webhooks.find(params[:id])

    if channel_group_webhook.destroy
      redirect_to my_notification_settings_path, notice: "Channel group webhook was successfully destroyed."
    else
      redirect_to my_notification_settings_path, alert: "Failed to destroy channel group webhook."
    end
  end

  def channel_group_webhook_params
    params.require(:channel_group_webhook).permit(:channel_group_id, :url)
  end
end
