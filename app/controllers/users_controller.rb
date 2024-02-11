class UsersController < ApplicationController
  def show
    @user = User.find_by(name: params[:user_name])
    @owned_channels = @user.owned_channels.order("ownerships.id DESC")
    @subscribed_channels = @user.subscribed_channels.order("subscriptions.id DESC")

    @title = "@" + @user.name
  end
end
