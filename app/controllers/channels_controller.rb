class ChannelsController < ApplicationController
  before_action :login_required, only: %i[create]

  def index
    page = (params[:page].presence || 1).to_i
    @channels = Channel.order(id: :desc).page(page)

    @title = page == 1 ? "Channels" : "Channels (Page #{page})"
  end

  def show
    @channel = Channel.find(params[:channel_id])
    @items = @channel.items.order(published_at: :desc, title: :desc)

    @title = @channel.title
  end

  def create
    url = params[:url]

    if channel = Channel.add(url)
      flash[:notice] = "Channel added successfully"
      redirect_to channel
    else
      flash[:alert] = "Can't find feed from '#{url}'"

      redirect_to root_path
    end
  end
end
