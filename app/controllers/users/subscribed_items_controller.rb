class Users::SubscribedItemsController < ApplicationController
  def index
    @user = User.find_by(name: params[:user_name])
    @subscribed_items = @user.subscribed_items.order(id: :desc).limit(60)

    respond_to do |format|
      format.atom
      format.json
    end
  end
end
