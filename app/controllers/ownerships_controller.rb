class OwnershipsController < ApplicationController
  before_action :login_required
  before_action :set_channel

  def create
    current_user.add_channel(@channel)
    DiscoPosterJob.perform_later(content: "@#{current_user.name} added #{@channel.title} to their own channels <#{channel_url(@channel)}>", channel: :user_activities)

    redirect_to @channel
  end

  def destroy
    current_user.remove_channel(@channel)

    redirect_to @channel
  end

  def set_channel
    @channel = Channel.find(params[:channel_id])
  end
end
