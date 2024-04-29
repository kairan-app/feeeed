class NotificationEmails::VerificationsController < ApplicationController
  def create
    notification_email = NotificationEmail.find_by(verification_token: params[:token])
    raise ActiveRecord::RecordNotFound if notification_email.nil?

    notification_email.touch(:verified_at)
    redirect_to root_path, notice: "Email #{notification_email.email} verified."
  end
end
