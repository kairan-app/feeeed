class ClosedBetaController < ApplicationController
  def show
    @join_request = JoinRequest.new
    @title = "Closed Beta"
  end

  def request_access
    # Google認証の結果を受け取る
    payload = Google::Auth::IDTokens.verify_oidc(
      params[:credential],
      aud: Rails.application.credentials.google_auth_app.client_id
    )

    email = payload["email"]
    icon_url = payload["picture"]

    # 既存ユーザーの場合はログインさせる
    user = User.find_by(google_guid: payload["sub"])
    if user
      log_in(user)
      return redirect_to root_path, notice: "Logged in"
    end

    # JoinRequestを作成または更新
    join_request = JoinRequest.find_or_initialize_by(email: email)
    join_request.icon_url = icon_url
    join_request.comment = params[:comment]

    if join_request.save
      # Discord通知を送信
      JoinRequestNotifierJob.perform_later(join_request)
      redirect_to closed_beta_path, notice: "リクエストを受け付けました。承認されるまでお待ちください。"
    else
      redirect_to closed_beta_path, alert: "リクエストの送信に失敗しました。"
    end
  rescue Google::Auth::IDTokens::VerificationError => e
    redirect_to closed_beta_path, alert: "認証に失敗しました。"
  end

  private

  def verify_g_csrf_token
    if cookies["g_csrf_token"].blank? || params[:g_csrf_token].blank? || cookies["g_csrf_token"] != params[:g_csrf_token]
      redirect_to closed_beta_path, alert: "Invalid access"
    end
  end
end
