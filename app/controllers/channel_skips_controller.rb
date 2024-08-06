class ChannelSkipsController < ApplicationController
  before_action :login_required

  def create
    @channel = Channel.find(params[:channel_id])

    @items_to_skip = @channel.items.where.not(id: current_user.item_skips.pluck(:item_id))
    @items_to_skip.each do |item|
      current_user.skip(item)
    end
  end
end
