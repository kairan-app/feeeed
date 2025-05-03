class Feeds::ChannelsController < ApplicationController
  def index
    @channels = Channel.order(created_at: :desc).limit(100)

    respond_to do |format|
      format.atom
    end
  end
end
