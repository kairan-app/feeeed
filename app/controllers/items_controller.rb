class ItemsController < ApplicationController
  def index
    page = (params[:page].presence || 1).to_i
    @items = Item.preload(:pawprints).eager_load(:channel).order(published_at: :desc, title: :desc).page(page)

    @title = page == 1 ? "Items" : "Items (Page #{page})"
  end
end
