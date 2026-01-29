class SubscriptionsController < ApplicationController
  before_action :login_required
  before_action :set_channel

  def create
    current_user.subscribe(@channel)
    @subscribed_channel_ids = current_user.subscribed_channel_ids
    @subscriptions_by_channel_id = current_user.subscriptions.includes(:subscription_tags).index_by(&:channel_id)
    @subscription_tags_ordered = current_user.subscription_tags.ordered
    DiscoPosterJob.perform_later(content: "@#{current_user.name} subscribed to #{@channel.title} <#{channel_url(@channel)}>", channel: :user_activities)

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @channel }
    end
  end

  def destroy
    current_user.unsubscribe(@channel)
    @subscribed_channel_ids = current_user.reload.subscribed_channel_ids
    @subscriptions_by_channel_id = current_user.subscriptions.includes(:subscription_tags).index_by(&:channel_id)
    @subscription_tags_ordered = current_user.subscription_tags.ordered

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @channel }
    end
  end

  private

  def set_channel
    @channel = Channel.find(params[:channel_id])
  end
end
