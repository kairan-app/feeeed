class ReactionsController < ApplicationController
  before_action :login_required, only: %i[create destroy]
  before_action :set_item, only: %i[create destroy]

  def index
    @reactions = Reaction.eager_load(:user, :item).order(id: :desc).page(params[:page])

    @title = "Reactions"
  end

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
