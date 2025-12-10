class MembershipsController < ApplicationController
  before_action :login_required

  def create
    channel_group = ChannelGroup.find(params[:id])
    current_user.join(channel_group)
    DiscoPosterJob.perform_later(content: "@#{current_user.name} joined the channel group: #{channel_group.name} <#{channel_group_url(channel_group)}>", channel: :user_activities)

    redirect_to channel_group
  end

  def destroy
    channel_group = ChannelGroup.find(params[:id])
    current_user.leave(channel_group)
    DiscoPosterJob.perform_later(content: "@#{current_user.name} left the channel group: #{channel_group.name} <#{channel_group_url(channel_group)}>", channel: :user_activities)

    redirect_to channel_group
  end
end
