class My::ProfileController < MyController
  def show
    @user = current_user

    @title = "My Profile"
  end

  def update
    @user = current_user

    if params[:avatar].present?
      if validate_avatar(params[:avatar])
        @user.avatar.attach(params[:avatar])
      else
        redirect_to my_profile_path, alert: "Invalid image file. Please upload JPG, PNG, GIF, or WebP under 5MB."
        return
      end
    end

    if params[:name].present?
      @user.name = params[:name]
    end

    if @user.save
      redirect_to my_profile_path, notice: "Profile updated"
    else
      redirect_to my_profile_path, alert: "Profile update failed: #{@user.errors.full_messages.join(', ')}"
    end
  end

  private

  def validate_avatar(file)
    return false unless file.respond_to?(:content_type)

    valid_types = %w[image/jpeg image/jpg image/png image/gif image/webp]
    max_size = 5.megabytes

    valid_types.include?(file.content_type) && file.size <= max_size
  end
end
