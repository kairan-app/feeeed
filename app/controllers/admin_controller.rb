class AdminController < ApplicationController
  before_action :login_required
  before_action :admin_required

  private

  def admin_required
    unless current_user.admin?
      flash[:alert] = "You must be an admin to access this section"
      redirect_to root_path
    end
  end
end
