class AdminController < ApplicationController
  before_action :admin_required

  def index
    @title = "Admin"
  end

  private

  def admin_required
    unless current_user&.admin?
      render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
    end
  end
end
