class WelcomeController < ApplicationController
  def index
    @channels = Channel.order(id: :desc).limit(10)
    @items = Item.preload(:pawprints).eager_load(:channel).order(published_at: :desc, title: :desc).limit(12)
    @pawprints = Pawprint.order(id: :desc).limit(15)

    @title = "Feed Network"
  end
end
