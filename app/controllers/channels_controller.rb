class ChannelsController < ApplicationController
  before_action :login_required, only: %i[create]

  def index
    page = (params[:page].presence || 1).to_i
    @channels = Channel.order(id: :desc).page(page)

    @title = page == 1 ? "Channels" : "Channels (Page #{page})"
  end

  def show
    @channel = Channel.find(params[:channel_id])
    @items = @channel.items.order(published_at: :desc)

    @title = @channel.title
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
