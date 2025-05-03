class ChannelsController < ApplicationController
  before_action :login_required, only: %i[create]

  def index
    page = (params[:page].presence || 1).to_i
    @channel_q = Channel.ransack(params[:channel_q])
    @channels = @channel_q.result.order(id: :desc).page(page).per(60)

    @title = page == 1 ? "Channels" : "Channels (Page #{page})"
  end

  def show
    page = (params[:page].presence || 1).to_i
    @channel = Channel.find(params[:channel_id])
    @items = @channel.items.preload(:pawprints).order(published_at: :desc, title: :desc).page(page).per(48)
    @noindex = true

    @title = @channel.title
  end

  def create
    url = params[:url]

    DiscoPosterJob.perform_later(content: "@#{current_user.name} try to add #{url}")

    channel = Channel.add(url)

    if channel.nil?
      flash[:alert] = "Can't find feed from '#{url}'"
      redirect_to root_path
    elsif !channel.persisted?
      flash[:alert] = "Can't save channel from '#{url}'"
      redirect_to root_path
    else
      flash[:notice] = "Channel added successfully"
      redirect_to channel
    end
  end
end
