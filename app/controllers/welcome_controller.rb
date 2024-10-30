class WelcomeController < ApplicationController
  def index
    @channels =
      Channel.
        joins(:items).
        select("channels.*, MAX(items.id) AS max_item_id").
        group("channels.id").
        order("max_item_id DESC").
        limit(3)

    @title = "Enjoy feeds!"
  end
end
