class NotificationEmailMailer < ApplicationMailer
  def please_verify(notification_email)
    @notification_email = notification_email
    @user = notification_email.user
    @verification_url = notification_email_verification_url(token: notification_email.verification_token)

    mail(to: @notification_email.email, subject: "feeeed")
  end
end
