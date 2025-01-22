class PawprintsController < ApplicationController
  before_action :login_required
  before_action :set_item, only: %i[create destroy]

  def index
    @pawprints = Pawprint.eager_load(:user, :item).order(id: :desc).page(params[:page])

    @title = "Pawprints"
  end

  def create
    @pawprint = current_user.paw(@item, memo: params[:memo])
  end

  def destroy
    current_user.unpaw(@item)
  end

  def set_item
    @item = Item.find(params[:item_id])
  end
end
