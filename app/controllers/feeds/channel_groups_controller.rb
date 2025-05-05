class Feeds::ChannelGroupsController < ApplicationController
  def index
    @channel_groups = ChannelGroup.order(id: :desc).limit(100)

    respond_to do |format|
      format.atom
    end
  end
end
