class ApplicationController < ActionController::Base
  include SessionHelper

  before_action :set_subscribed_channel_ids

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
end
