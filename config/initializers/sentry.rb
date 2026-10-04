Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.breadcrumbs_logger = %i[active_support_logger http_logger]

  # 定数は呼ばれたときに引く (初期化の時点では autoload の対象を参照しない)
  config.traces_sampler = ->(sampling_context) { SentryTracesSampler.call(sampling_context) }
end
