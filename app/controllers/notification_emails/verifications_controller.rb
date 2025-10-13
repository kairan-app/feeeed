class NotificationEmails::VerificationsController < ApplicationController
  def create
    notification_email = NotificationEmail.find_by(verification_token: params[:token])
    raise ActiveRecord::RecordNotFound if notification_email.nil?

    notification_email.touch(:verified_at)
    DiscoPosterJob.perform_later(content: "@#{notification_email.user.name} verified notification email (id:#{notification_email.id})", channel: :user_activities)
    redirect_to my_notification_settings_path, notice: "Email #{notification_email.email} verified."
  end
end
