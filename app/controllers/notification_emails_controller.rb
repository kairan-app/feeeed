class NotificationEmailsController < ApplicationController
  before_action :login_required

  def create
    ne = current_user.notification_emails.new(notification_email_params)

    if ne.save
      DiscoPosterJob.perform_later(content: "@#{current_user.name} added a notification email (mode: #{ne.mode})", channel: :user_activities)
      redirect_to my_notification_settings_path, notice: "Verification email sent. Please check your inbox."
    else
      redirect_to my_notification_settings_path, alert: ne.errors.full_messages.join(", ")
    end
  end

  def destroy
    ne = current_user.notification_emails.find(params[:id])
    ne.destroy
    redirect_to my_notification_settings_path, notice: "Notification email was successfully destroyed."
  end

  def notification_email_params
    params.require(:notification_email).permit(:email, :mode, :notify_hour)
  end
end
