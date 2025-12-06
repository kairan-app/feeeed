class AdminController < ApplicationController
  before_action :admin_required

  def index
    @title = "Admin"

    # Counts
    @users_count = User.count
    @channels_count = Channel.count
    @items_count = Item.count
    @pawprints_count = Pawprint.count
    @subscriptions_count = Subscription.count
    @notification_emails_count = NotificationEmail.count
    @notification_webhooks_count = NotificationWebhook.count

    # Join Requests
    @join_requests_count = JoinRequest.count
    @pending_join_requests_count = JoinRequest.pending.count

    # Active users (based on Ahoy::Event)
    @active_users_24h = Ahoy::Event.where("time > ?", 24.hours.ago).select(:user_id).distinct.count
    @active_users_3d = Ahoy::Event.where("time > ?", 3.days.ago).select(:user_id).distinct.count

    # Additional stats
    @channel_groups_count = ChannelGroup.count
    @stopped_channels_count = ChannelStopper.count
    @channel_group_webhooks_count = ChannelGroupWebhook.count

    # Recent activity
    @items_today_count = Item.where("created_at > ?", Time.current.beginning_of_day).count
    @channels_24h_count = Channel.where("created_at > ?", 24.hours.ago).count

    # Ahoy stats
    @events_count = Ahoy::Event.count
    @events_today_count = Ahoy::Event.where("time > ?", Time.current.beginning_of_day).count
    @visits_count = Ahoy::Visit.count
    @visits_today_count = Ahoy::Visit.where("started_at > ?", Time.current.beginning_of_day).count

    # Jobs (Solid Queue)
    @jobs_pending_count = SolidQueue::ReadyExecution.count
    @jobs_failed_count = SolidQueue::FailedExecution.count
    @jobs_24h_count = SolidQueue::Job.where("created_at > ?", 24.hours.ago).count
  end

  private

  def admin_required
    unless current_user&.admin?
      render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
    end
  end
end
