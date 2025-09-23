Rails.application.config.after_initialize do
  if defined?(MissionControl::Jobs)
    # Apply configuration directly to the module
    MissionControl::Jobs.base_controller_class = "::AdminController"
    MissionControl::Jobs.http_basic_auth_enabled = false

    # Override BasicAuthentication module to prevent 401 errors
    if defined?(MissionControl::Jobs::BasicAuthentication)
      MissionControl::Jobs::BasicAuthentication.module_eval do
        def authenticate_by_http_basic
          # Skip basic auth - authentication is handled by AdminController
        end

        def http_basic_auth_enabled?
          false
        end
      end
    end
  end
end
