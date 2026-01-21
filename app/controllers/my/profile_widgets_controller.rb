class My::ProfileWidgetsController < MyController
  def index
    @profile_widgets = current_user.profile_widgets.ordered
    @available_widget_types = available_widget_types
    @title = "Profile Widgets"
  end

  def create
    @profile_widget = current_user.profile_widgets.build(profile_widget_params)

    if @profile_widget.save
      redirect_to my_profile_widgets_path
    else
      redirect_to my_profile_widgets_path, alert: @profile_widget.errors.full_messages.join(", ")
    end
  end

  def destroy
    @profile_widget = current_user.profile_widgets.find(params[:id])
    @profile_widget.destroy
    redirect_to my_profile_widgets_path
  end

  def move_up
    @profile_widget = current_user.profile_widgets.find(params[:id])
    @profile_widget.move_up
    redirect_to my_profile_widgets_path
  end

  def move_down
    @profile_widget = current_user.profile_widgets.find(params[:id])
    @profile_widget.move_down
    redirect_to my_profile_widgets_path
  end

  private

  def profile_widget_params
    params.require(:profile_widget).permit(:widget_type)
  end

  def available_widget_types
    enabled_types = current_user.profile_widgets.pluck(:widget_type)
    UserProfileWidget.widget_types.keys.reject { |type| enabled_types.include?(type) }
  end
end
