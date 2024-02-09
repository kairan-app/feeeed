class WelcomeController < ApplicationController
  def index
    @channels = Channel.order(id: :desc).limit(5)
    @items = Item.preload(:channel).order(published_at: :desc).limit(5)

    @title = "Feed Network"
  end
end
