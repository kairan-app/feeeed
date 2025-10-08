class Channels::FetchController < ApplicationController
  before_action :login_required

  def create
    channel = Channel.find(params[:channel_id])
    ChannelItemsUpdaterJob.perform_later(channel_id: channel.id, mode: :only_recent)
    DiscoPosterJob.perform_later(content: "@#{current_user.name} requested to update #{channel.title}", channel: :user_activities)

    redirect_to channel, notice: "Channel updated, and fetching items in the background."
  end
end
