class MembershipsController < ApplicationController
  before_action :login_required

  def create
    channel_group = ChannelGroup.find(params[:id])
    current_user.join_to(channel_group)

    redirect_to channel_group
  end

  def destroy
    channel_group = ChannelGroup.find(params[:id])
    current_user.leave(channel_group)

    redirect_to channel_group
  end
end
