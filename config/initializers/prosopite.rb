if Rails.env.development?
  Prosopite.setup do |config|
    config.enabled = true
    config.raise = false
    config.rails_logger = true
    config.prosopite_logger = true
    config.stderr_logger = false
  end
end