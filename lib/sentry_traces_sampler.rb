# Sentry に送る transaction の割合を決める。全件送ると1日に2万件を超えて枠を使い切るので、
# リクエストは少し、大量に動くジョブはもっと薄く送り、見る価値の低いものは送らない
module SentryTracesSampler
  HTTP_RATE = 0.05
  JOB_RATE = 0.01

  # ヘルスチェックと、毎時のスケジュールで動くだけのジョブ
  IGNORED_PATHS = %w[/up].freeze
  IGNORED_JOBS = %w[
    ChannelItemsFetcherJob
    FetcherLagMonitorJob
    NotificationWebhookDispatcherJob
    NotificationEmailDispatcherJob
    ChannelGroupWebhookDispatcherJob
  ].freeze

  def self.call(sampling_context)
    transaction = sampling_context[:transaction_context] || {}

    case transaction[:op]
    when "http.server"
      path = sampling_context.dig(:env, "PATH_INFO")
      IGNORED_PATHS.include?(path) ? 0.0 : HTTP_RATE
    when "queue.process"
      IGNORED_JOBS.include?(transaction[:name]) ? 0.0 : JOB_RATE
    else
      JOB_RATE
    end
  end
end
