class ChannelGroupingsController < ApplicationController
  before_action :login_required

  def create
    cg = ChannelGrouping.create(channel_id: params[:channel_id], channel_group_id: params[:channel_group_id])

    DiscoPosterJob.perform_later(content: "@#{current_user.name} added #{cg.channel.title} to #{cg.channel_group.name}")
    redirect_to cg.channel, notice: "Channel added to group"
  end
end
