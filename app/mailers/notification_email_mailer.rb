class NotificationEmailMailer < ApplicationMailer
  def please_verify(notification_email)
    @notification_email = notification_email
    @user = notification_email.user
    @verification_url = notification_email_verification_url(token: notification_email.verification_token)

    mail(to: @notification_email.email, subject: "Please verify your email address")
  end

  def pawprints(notification_email:, pawprints:)
    return unless notification_email.verified?
    return if pawprints.empty?

    @notification_email = notification_email
    @pawprints = pawprints
    @user = notification_email.user

    mail(to: @notification_email.email, subject: "@#{notification_email.user.name}'s recent pawprints 🐾")
  end

  def subscribed_items(notification_email:, channel_and_items:, subject:)
    return unless notification_email.verified?
    return if channel_and_items.empty?

    @notification_email = notification_email
    @channel_and_items = channel_and_items
    @user = notification_email.user

    mail(to: @notification_email.email, subject: subject)
  end
end
