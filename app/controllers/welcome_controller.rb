class WelcomeController < ApplicationController
  def index
    @pawprints =
      Pawprint.
        order(id: :desc).
        limit(12)

    @channel_groups =
      ChannelGroup.
        order(id: :desc).
        limit(12)

    @channel_and_items =
      Channel.
        joins(:items).
        select("channels.*, MAX(items.id) AS max_item_id").
        group("channels.id").
        order("max_item_id DESC").
        limit(12)

    @channels =
      Channel.
        order(updated_at: :desc).
        limit(12)

    @title = "Enjoy feeds!"
  end
end
