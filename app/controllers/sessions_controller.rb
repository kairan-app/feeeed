require "googleauth/id_tokens/verifier"

class SessionsController < ApplicationController
  protect_from_forgery except: :create

  def create
    # JSONリクエストとフォームリクエストの両方に対応
    credential = params[:credential] || JSON.parse(request.body.read)['credential'] rescue params[:credential]

    payload = Google::Auth::IDTokens.verify_oidc(
      credential,
      aud: Rails.application.credentials.google_auth_app.client_id
    )

    # 既存ユーザーをチェック
    user = User.find_by(google_guid: payload["sub"])

    if user
      # 登録済みユーザーの場合はログイン
      log_in(user)
      redirect_to root_path, notice: "Logged in"
    else
      email = payload["email"]

      # 承認済みのJoinRequestがあるかチェック
      join_request = JoinRequest.approved.find_by(email:)

      if join_request
        # 承認済みの場合はユーザーを作成してログイン
        user = User.create!(
          google_guid: payload["sub"],
          email: email,
          name: email.split("@").first,
          icon_url: payload["picture"]
        )
        log_in(user)
        redirect_to root_path, notice: "Logged in"
      else
        # 未承認の場合は認証情報をセッションに保存してjoin_requests#newへ
        session[:pending_auth] = {
          "google_guid" => payload["sub"],
          "email" => email,
          "icon_url" => payload["picture"],
          "name" => email.split("@").first
        }
        redirect_to new_join_request_path
      end
    end
  end

  def destroy
    log_out
    redirect_to root_path, notice: "Logged out"
  end
end
