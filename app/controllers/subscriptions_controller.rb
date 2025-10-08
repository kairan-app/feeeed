class SubscriptionsController < ApplicationController
  before_action :login_required
  before_action :set_channel

  def create
    current_user.subscribe(@channel)
    DiscoPosterJob.perform_later(content: "@#{current_user.name} subscribed to #{@channel.title} #{channel_url(@channel)}", channel: :user_activities)

    redirect_to @channel
  end

  def destroy
    current_user.unsubscribe(@channel)

    redirect_to @channel
  end

  def set_channel
    @channel = Channel.find(params[:channel_id])
  end
end
