class AdminController < ApplicationController
  before_action :admin_required

  def index
    @title = "Admin"

    # Users
    @users_count = User.count
    @users_24h_count = User.where("created_at > ?", 24.hours.ago).count
    @users_7d_count = User.where("created_at > ?", 7.days.ago).count
    @active_users_24h = Ahoy::Event.where("time > ?", 24.hours.ago).select(:user_id).distinct.count
    @active_users_7d = Ahoy::Event.where("time > ?", 7.days.ago).select(:user_id).distinct.count

    # Channels
    @channels_count = Channel.count
    @channels_24h_count = Channel.where("created_at > ?", 24.hours.ago).count
    @channels_7d_count = Channel.where("created_at > ?", 7.days.ago).count
    @stopped_channels_count = ChannelStopper.count

    # Items
    @items_count = Item.count
    @items_24h_count = Item.where("created_at > ?", 24.hours.ago).count
    @items_7d_count = Item.where("created_at > ?", 7.days.ago).count

    # Pawprints
    @pawprints_count = Pawprint.count
    @pawprints_24h_count = Pawprint.where("created_at > ?", 24.hours.ago).count
    @pawprints_7d_count = Pawprint.where("created_at > ?", 7.days.ago).count

    # Subscriptions
    @subscriptions_count = Subscription.count
    @subscriptions_24h_count = Subscription.where("created_at > ?", 24.hours.ago).count
    @subscriptions_7d_count = Subscription.where("created_at > ?", 7.days.ago).count

    # Channel Groups
    @channel_groups_count = ChannelGroup.count
    @channel_groups_24h_count = ChannelGroup.where("created_at > ?", 24.hours.ago).count
    @channel_groups_7d_count = ChannelGroup.where("created_at > ?", 7.days.ago).count

    # Join Requests
    @join_requests_count = JoinRequest.count
    @join_requests_24h_count = JoinRequest.where("created_at > ?", 24.hours.ago).count
    @join_requests_7d_count = JoinRequest.where("created_at > ?", 7.days.ago).count
    @pending_join_requests_count = JoinRequest.pending.count

    # Notification Emails
    @notification_emails_count = NotificationEmail.count
    @notification_emails_24h_count = NotificationEmail.where("created_at > ?", 24.hours.ago).count
    @notification_emails_7d_count = NotificationEmail.where("created_at > ?", 7.days.ago).count

    # Notification Webhooks
    @notification_webhooks_count = NotificationWebhook.count
    @notification_webhooks_24h_count = NotificationWebhook.where("created_at > ?", 24.hours.ago).count
    @notification_webhooks_7d_count = NotificationWebhook.where("created_at > ?", 7.days.ago).count

    # Channel Group Webhooks
    @channel_group_webhooks_count = ChannelGroupWebhook.count
    @channel_group_webhooks_24h_count = ChannelGroupWebhook.where("created_at > ?", 24.hours.ago).count
    @channel_group_webhooks_7d_count = ChannelGroupWebhook.where("created_at > ?", 7.days.ago).count

    # Proxy Required Domains
    @proxy_required_domains_count = ProxyRequiredDomain.count
    @proxy_required_domains_24h_count = ProxyRequiredDomain.where("created_at > ?", 24.hours.ago).count
    @proxy_required_domains_7d_count = ProxyRequiredDomain.where("created_at > ?", 7.days.ago).count

    # Jobs (Solid Queue)
    @jobs_pending_count = SolidQueue::ReadyExecution.count
    @jobs_24h_count = SolidQueue::Job.where("created_at > ?", 24.hours.ago).count
    @jobs_7d_count = SolidQueue::Job.where("created_at > ?", 7.days.ago).count
    @jobs_failed_count = SolidQueue::FailedExecution.count

    # Events (Ahoy)
    @events_count = Ahoy::Event.count
    @events_24h_count = Ahoy::Event.where("time > ?", 24.hours.ago).count
    @events_7d_count = Ahoy::Event.where("time > ?", 7.days.ago).count

    # Visits (Ahoy)
    @visits_count = Ahoy::Visit.count
    @visits_24h_count = Ahoy::Visit.where("started_at > ?", 24.hours.ago).count
    @visits_7d_count = Ahoy::Visit.where("started_at > ?", 7.days.ago).count
  end

  private

  def admin_required
    unless current_user&.admin?
      render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
    end
  end
end
