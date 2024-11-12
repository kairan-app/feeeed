class WelcomeController < ApplicationController
  def index
    @pawprints =
      Pawprint.
        order(created_at: :desc).
        limit(12)
    @channel_groups =
      ChannelGroup.
      all.
      order(created_at: :desc).
      limit(5)
    @channels =
      Channel.
        joins(:items).
        select("channels.*, MAX(items.id) AS max_item_id").
        group("channels.id").
        order("max_item_id DESC").
        limit(12)

    @title = "Enjoy feeds!"
  end
end
