class UsersController < ApplicationController
  def show
    @user = User.find_by(name: params[:user_name])
    @profile_widgets = @user.profile_widgets.ordered

    @title = "@" + @user.name
  end
end
