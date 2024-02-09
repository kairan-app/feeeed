class ApplicationController < ActionController::Base
  include SessionHelper

  def login_required
    if current_user.nil?
      flash[:error] = "You must be logged in to access this section"
      redirect_to login_path
    end
  end
end
