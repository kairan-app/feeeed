class NotificationWebhooksController < ApplicationController
  before_action :login_required

  def create
    nw = current_user.notification_webhooks.new(notification_webhook_params)

    if nw.save
      DiscoPosterJob.perform_later(content: "@#{current_user.name} added a notification webhook (mode: #{nw.mode})")
      redirect_to my_notification_settings_path, notice: "Notification webhook was successfully created."
    else
      redirect_to my_notification_settings_path, alert: nw.errors.full_messages.join(", ")
    end
  end

  def destroy
    nw = current_user.notification_webhooks.find(params[:id])
    nw.destroy

    redirect_to my_notification_settings_path, notice: "Notification webhook was successfully destroyed."
  end

  def notification_webhook_params
    params.require(:notification_webhook).permit(:url, :mode)
  end
end
