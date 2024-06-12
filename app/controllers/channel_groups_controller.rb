class ChannelGroupsController < ApplicationController
  def index
    page = (params[:page].presence || 1).to_i
    @channel_groups = ChannelGroup.order(id: :desc).page(page).per(60)
  end

  def show
    @channel_group = ChannelGroup.find(params[:id])
  end

  def new
    @channel_group = ChannelGroup.new
  end

  def create
    @channel_group = ChannelGroup.new(channel_group_params)
    if @channel_group.save
      redirect_to(channel_group_path(@channel_group), notice: "Channel Group created")
    else
      render(:new, status: :unprocessable_entity)
    end
  end

  def channel_group_params
    params.require(:channel_group).permit(:name)
  end
end
