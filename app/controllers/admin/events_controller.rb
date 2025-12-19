class Admin::EventsController < AdminController
  def index
    @events = Ahoy::Event.includes(:user, :visit).order(time: :desc)

    # Filter by user_id
    if params[:user_id].present?
      @events = @events.where(user_id: params[:user_id])
    end

    # Filter by event name
    if params[:name].present?
      @events = @events.where(name: params[:name])
    end

    # Filter by properties (partial match in JSON)
    if params[:properties].present?
      @events = @events.where("properties::text ILIKE ?", "%#{params[:properties]}%")
    end

    @events = @events.page(params[:page]).per(50)
    @event_names = Ahoy::Event.distinct.pluck(:name).compact.sort
    @event_users = User.where(id: Ahoy::Event.distinct.pluck(:user_id)).order(:name)
    @title = "Events"
  end
end
