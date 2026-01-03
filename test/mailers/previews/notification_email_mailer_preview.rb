class NotificationEmailMailerPreview < ActionMailer::Preview
  def please_verify
    notification_email = NotificationEmail.first || build_sample_notification_email
    NotificationEmailMailer.please_verify(notification_email)
  end

  def pawprints
    notification_email = NotificationEmail.only_verified.first || build_sample_notification_email(verified: true)
    pawprints = Pawprint.limit(5)
    pawprints = build_sample_pawprints if pawprints.empty?

    NotificationEmailMailer.pawprints(notification_email: notification_email, pawprints: pawprints)
  end

  def subscribed_items
    notification_email = NotificationEmail.only_verified.first || build_sample_notification_email(verified: true)
    channel_ids = Item.select(:channel_id).distinct.limit(2).pluck(:channel_id)
    channel_and_items = Channel.where(id: channel_ids).map { |c| [ c, c.items.limit(3) ] }
    channel_and_items = build_sample_channel_and_items if channel_and_items.empty?

    NotificationEmailMailer.subscribed_items(
      notification_email: notification_email,
      channel_and_items: channel_and_items,
      subject: "New arrival items!"
    )
  end

  private

  def build_sample_notification_email(verified: false)
    user = User.first || User.new(name: "sample_user")
    NotificationEmail.new(
      user: user,
      email: "sample@example.com",
      verification_token: "sample_token",
      verified_at: verified ? Time.current : nil
    )
  end

  def build_sample_pawprints
    item = Item.first || Item.new(title: "Sample Item", url: "https://example.com")
    [
      Pawprint.new(item: item, memo: "Great article!", created_at: 1.hour.ago),
      Pawprint.new(item: item, memo: nil, created_at: 2.hours.ago)
    ]
  end

  def build_sample_channel_and_items
    channel = Channel.new(title: "Sample Channel", site_url: "https://example.com")
    items = [
      Item.new(title: "Article 1", url: "https://example.com/1", published_at: 1.hour.ago),
      Item.new(title: "Article 2", url: "https://example.com/2", published_at: 2.hours.ago)
    ]
    [ [ channel, items ] ]
  end
end
