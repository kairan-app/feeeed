class Admin::JoinRequests::ApprovalsController < AdminController
  def create
    @join_request = JoinRequest.find(params[:id])

    if @join_request.approve_by(current_user)
      redirect_to admin_join_requests_path, notice: "#{@join_request.email}を承認しました"
    else
      redirect_to admin_join_requests_path, alert: "承認に失敗しました"
    end
  end
end
