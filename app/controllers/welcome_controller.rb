class WelcomeController < ApplicationController
  def index
    @channels = Channel.order(id: :desc).limit(12)
    @items = Item.preload(:reactions).eager_load(:channel).order(published_at: :desc, title: :desc).limit(12)

    @title = "Feed Network"
  end
end
