class ChannelSkipsController < ApplicationController
  before_action :login_required

  def create
    @channel = current_user.subscribed_channels.find(params[:channel_id])

    @items_to_skip = @channel.items.where.not(id: current_user.item_skips.pluck(:item_id))
    @items_to_skip.each do |item|
      current_user.skip(item)
    end
  end
end
