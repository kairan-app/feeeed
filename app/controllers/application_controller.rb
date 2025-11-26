class ApplicationController < ActionController::Base
  include SessionHelper

  before_action :set_subscribed_channel_ids
  after_action :track_action

  def login_required
    if current_user.nil?
      flash[:alert] = "You must be logged in to access this section"
      redirect_to root_path
    end
  end

  private

  def set_subscribed_channel_ids
    @subscribed_channel_ids = current_user&.subscribed_channel_ids || []
  end

  def track_action
    return if turbo_prefetch_request?

    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(params.except(:controller, :action).to_unsafe_h)
    ahoy.track "#{controller_name}##{action_name}", filtered
  end

  def turbo_prefetch_request?
    request.headers["Purpose"] == "prefetch" ||
      request.headers["Sec-Purpose"] == "prefetch" ||
      request.headers["X-Sec-Purpose"] == "prefetch"
  end
end
