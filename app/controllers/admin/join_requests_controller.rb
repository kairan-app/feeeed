class Admin::JoinRequestsController < AdminController
  def index
    @pending_requests = JoinRequest.pending.recent
    @approved_requests = JoinRequest.approved.recent.limit(20)
    @title = "Join Requests"
  end
end
