class Admin::JoinRequestsController < AdminController
  def index
    @pending_requests = JoinRequest.pending.order(id: :desc)
    @approved_requests = JoinRequest.approved.order(id: :desc).limit(20)
    @title = "Join Requests"
  end
end
