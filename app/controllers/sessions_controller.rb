require "googleauth/id_tokens/verifier"

class SessionsController < ApplicationController
  protect_from_forgery except: :create
  before_action :verify_g_csrf_token, only: :create

  def create
    payload = Google::Auth::IDTokens.verify_oidc(
      params[:credential],
      aud: Rails.application.credentials.google_auth_app.client_id
    )
    email = payload["email"]

    unless ENV["ALLOWED_EMAILS"].split(",").include?(email)
      DiscoPosterJob.perform_later(content: "#{email} tried to log in")
      return redirect_to root_path
    end

    user = User.find_or_initialize_by(google_guid: payload["sub"])
    user.email ||= email
    user.name ||= email.split("@").first
    user.icon_url = payload["picture"]
    user.save

    log_in(user)
    redirect_to root_path, notice: "Logged in"
  end

  def destroy
    log_out
    redirect_to root_path, notice: "Logged out"
  end

  def verify_g_csrf_token
    if cookies["g_csrf_token"].blank? || params[:g_csrf_token].blank? || cookies["g_csrf_token"] != params[:g_csrf_token]
      redirect_to root_path, notice: "Invalid access"
    end
  end
end
