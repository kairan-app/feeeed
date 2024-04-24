class Channels::FetchController < ApplicationController
  before_action :login_required

  def create
    channel = Channel.find(params[:channel_id])
    Channel.add(channel.feed_url)
    ChannelItemsUpdaterJob.perform_later(channel_id: channel.id)

    redirect_to channel, notice: "Channel updated, and fetching items in the background."
  end
end

