class My::ProfileController < MyController
  def show
    @user = current_user

    @title = "My Profile"
  end

  def update
    if current_user.update(name: params[:name])
      redirect_to my_profile_path, notice: "Profile updated"
    else
      redirect_to my_profile_path, alert: "Profile update failed"
    end
  end
end
