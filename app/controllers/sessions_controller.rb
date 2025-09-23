require "googleauth/id_tokens/verifier"

class SessionsController < ApplicationController
  protect_from_forgery except: :create
  before_action :verify_g_csrf_token, only: :create

  def create
    payload = Google::Auth::IDTokens.verify_oidc(
      params[:credential],
      aud: Rails.application.credentials.google_auth_app.client_id
    )
    user = User.find_or_initialize_by(google_guid: payload["sub"])
    email = payload["email"]
    local_part = email.split("@").first

    # 新規ユーザーの場合は承認チェック
    if user.new_record?
      # JoinRequestで承認されているかチェック
      join_request = JoinRequest.where(email: email).approved.first
      if join_request.nil?
        # 承認されていない場合は/closed_betaにリダイレクト
        return redirect_to closed_beta_path, alert: "アクセスリクエストを送信してください"
      end
    end

    user.email ||= email
    user.name ||= local_part

    if user.icon_url
      if user.icon_url.include?("googleusercontent.com")
        user.icon_url = payload["picture"]
      end
    else
      user.icon_url = payload["picture"]
    end

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
