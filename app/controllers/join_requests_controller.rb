class JoinRequestsController < ApplicationController
  before_action :ensure_pending_auth_data, only: [ :new, :create ]

  def new
    @join_request = JoinRequest.new
    @title = "Join Request"
  end

  def create
    email = session[:pending_auth]["email"]
    icon_url = session[:pending_auth]["icon_url"]

    @join_request = JoinRequest.find_or_initialize_by(email: email)
    @join_request.icon_url = icon_url
    @join_request.comment = params[:join_request][:comment]

    if @join_request.save
      JoinRequestNotifierJob.perform_later(@join_request)
      session.delete(:pending_auth)
      redirect_to root_path, notice: "リクエストを受け付けました。承認されるまでお待ちください。"
    else
      render :new, alert: "リクエストの送信に失敗しました。"
    end
  end

  private

  def ensure_pending_auth_data
    unless session[:pending_auth]
      redirect_to root_path, alert: "認証情報が見つかりません。もう一度ログインしてください。"
    end
  end
end
