class Admin::EventsController < AdminController
  def index
    @events = Ahoy::Event.includes(:user, :visit).order(time: :desc).page(params[:page]).per(50)
    @title = "Events"
  end
end
