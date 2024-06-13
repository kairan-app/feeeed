class ChannelGroupsController < ApplicationController
  before_action :login_required, only: %i[new create update]

  def index
    page = (params[:page].presence || 1).to_i
    @channel_groups = ChannelGroup.order(id: :desc).page(page).per(60)

    @title = "Channel Groups"
  end

  def show
    @channel_group = ChannelGroup.find(params[:id])

    @title = @channel_group.name
  end

  def new
    @channel_group = ChannelGroup.new
  end

  def create
    @channel_group = ChannelGroup.new(channel_group_params)

    if @channel_group.save
      DiscoPosterJob.perform_later(content: "@#{current_user.name} created a new channel group: #{@channel_group.name}")
      redirect_to(channel_group_path(@channel_group), notice: "Channel Group created")
    else
      render(:new, status: :unprocessable_entity)
    end
  end

  def update
    channel_group = ChannelGroup.find(params[:id])

    if channel_group.update(channel_group_params)
      redirect_to channel_group_path(channel_group), notice: "Channel Group updated"
    else
      redirect_to channel_group_path(channel_group), alert: "Channel Group update failed"
    end
  end

  def channel_group_params
    params.require(:channel_group).permit(:name)
  end
end
