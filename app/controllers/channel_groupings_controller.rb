class ChannelGroupingsController < ApplicationController
  before_action :login_required

  def create
    grouping = ChannelGrouping.create(channel_id: params[:channel_id], channel_group_id: params[:channel_group_id])

    DiscoPosterJob.perform_later(content: "@#{current_user.name} added #{grouping.channel.title} to #{grouping.channel_group.name}", channel: :user_activities)
    redirect_to grouping.channel, notice: "Channel added to group"
  end

  def destroy
    grouping = ChannelGrouping.find(params[:id])
    channel = grouping.channel
    grouping.destroy

    redirect_to channel, notice: "Channel removed from group"
  end
end
