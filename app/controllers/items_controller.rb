class ItemsController < ApplicationController
  def index
    @items = Item.order(published_at: :desc).page(params[:page])
  end
end
