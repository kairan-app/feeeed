class UsersController < ApplicationController
  def index
    @users = User.order("users.id DESC")

    @title = "Users"
  end

  def show
    @user = User.find_by(name: params[:user_name])
    @owned_channels = @user.owned_channels.order("ownerships.id DESC")
    @subscribed_channels = @user.subscribed_channels.order("subscriptions.id DESC")
    @channel_groups = @user.channel_groups.order("channel_groups.id DESC")

    @title = "@" + @user.name
  end
end
