class DevController < ApplicationController
  def login
    user = User.find(params[:user_id])
    log_in(user)
    redirect_to root_path, notice: "🔧 Dev: #{user.name} でログイン"
  end
end
