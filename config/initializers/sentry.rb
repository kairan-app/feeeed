Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.breadcrumbs_logger = %i[active_support_logger http_logger]

  config.traces_sampler = lambda do |context|
    true
  end
end
