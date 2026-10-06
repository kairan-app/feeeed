class ItemsController < ApplicationController
  def index
    page = (params[:page].presence || 1).to_i
    raise ActiveRecord::RecordNotFound if page > Item.max_pages

    # eager_load だと件数を数えるクエリが channels を JOIN した DISTINCT になり重いので、preload で別に引く
    @items = Item.published_before(Time.current).preload(:pawprints, :channel).order(published_at: :desc, title: :desc).page(page).per(48)

    @title = page == 1 ? "Items" : "Items (Page #{page})"
  end
end
