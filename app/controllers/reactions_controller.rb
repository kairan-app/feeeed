class ReactionsController < ApplicationController
  before_action :login_required
  before_action :set_item

  def create
    current_user.add_reaction(@item, memo: params[:memo])
  end

  def destroy
    current_user.remove_reaction(@item)
  end

  def set_item
    @item = Item.find(params[:item_id])
  end
end
