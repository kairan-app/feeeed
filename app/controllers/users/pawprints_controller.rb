class Users::PawprintsController < ApplicationController
  def index
    @user = User.find_by(name: params[:user_name])
    @pawprints = @user.pawprints.order(id: :desc).limit(60)

    respond_to do |format|
      format.atom
    end
  end
end
