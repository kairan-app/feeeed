class Admin::VisitsController < AdminController
  def index
    @visits = Ahoy::Visit.includes(:user).order(started_at: :desc).page(params[:page]).per(50)
    @title = "Visits"
  end
end
