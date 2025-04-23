class MyController < ApplicationController
  before_action :login_required

  def index
    @title = "Settings"
  end

  def destroy
    current_user.destroy
    reset_session
    redirect_to root_path, notice: "Account deleted, goodbye!"
  end
end
