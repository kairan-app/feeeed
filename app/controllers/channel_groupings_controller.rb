class ChannelGroupingsController < ApplicationController
  before_action :login_required

  def create
    grouping = ChannelGrouping.create(channel_id: params[:channel_id], channel_group_id: params[:channel_group_id])

    DiscoPosterJob.perform_later(content: "@#{current_user.name} added #{grouping.channel.title} to #{grouping.channel_group.name}")
    redirect_to grouping.channel, notice: "Channel added to group"
  end
end
