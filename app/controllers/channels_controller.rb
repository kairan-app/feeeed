class ChannelsController < ApplicationController
  before_action :login_required, only: %i[create]

  def index
    @channels = Channel.order(id: :desc).page(params[:page])
  end

  def show
    @channel = Channel.find(params[:channel_id])
    @items = @channel.items.order(published_at: :desc)
  end

  def create
    if Channel.add(params[:url])
      flash[:notice] = "Channel added successfully"
    else
      flash[:alert] = "Channel could not be added"
    end

    redirect_to root_path
  end
end
