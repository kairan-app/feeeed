class UsersController < ApplicationController
  def show
    @user = User.find_by(name: params[:user_name])
    @owned_channels = @user.owned_channels.order(id: :desc)
  end
end
