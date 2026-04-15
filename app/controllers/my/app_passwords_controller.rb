class My::AppPasswordsController < MyController
  def index
    @title = "My App Passwords"
    @active_app_passwords = current_user.app_passwords.active.order(created_at: :desc)
    @revoked_app_passwords = current_user.app_passwords.revoked.order(revoked_at: :desc)
    @new_app_password = current_user.app_passwords.build
  end

  def create
    name = params.dig(:app_password, :name).to_s.strip

    if name.blank?
      redirect_to my_app_passwords_path, alert: "Name can't be blank"
      return
    end

    @plain_token, @app_password = AppPassword.issue!(user: current_user, name: name)
    @title = "App Password Issued"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to my_app_passwords_path, alert: e.record.errors.full_messages.join(", ")
  end

  def destroy
    app_password = current_user.app_passwords.active.find(params[:id])
    app_password.revoke!
    redirect_to my_app_passwords_path, notice: "Revoked \"#{app_password.name}\""
  end
end
