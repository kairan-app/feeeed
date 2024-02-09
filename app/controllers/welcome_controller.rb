class WelcomeController < ApplicationController
  def index
    @channels = Channel.order(id: :desc).limit(5)
    @items = Item.order(published_at: :desc).limit(5)
  end
end
