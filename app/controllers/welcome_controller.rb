class WelcomeController < ApplicationController
  def index
    @channels = Channel.order(id: :desc).limit(12)
    @items = Item.preload(:channel).order(published_at: :desc).limit(12)

    @title = "Feed Network"
  end
end
