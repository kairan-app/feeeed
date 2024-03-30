class ItemSkipsController < ApplicationController
  before_action :login_required
  before_action :set_item

  def create
    @item_skip = current_user.skip(@item)
  end

  def destroy
    current_user.unskip(@item)
  end

  def set_item
    @item = Item.find(params[:item_id])
  end
end
