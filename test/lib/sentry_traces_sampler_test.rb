require "test_helper"

class SentryTracesSamplerTest < ActiveSupport::TestCase
  def sample(op:, name: nil, path: nil)
    context = { transaction_context: { op:, name: } }
    context[:env] = { "PATH_INFO" => path } if path
    SentryTracesSampler.call(context)
  end

  test "リクエストは HTTP_RATE で送る" do
    assert_equal SentryTracesSampler::HTTP_RATE, sample(op: "http.server", name: "/channels/1", path: "/channels/1")
  end

  test "ヘルスチェックは送らない" do
    assert_equal 0.0, sample(op: "http.server", name: "/up", path: "/up")
  end

  test "ジョブは JOB_RATE で送る" do
    assert_equal SentryTracesSampler::JOB_RATE, sample(op: "queue.process", name: "ChannelItemsUpdaterJob")
  end

  test "毎時のスケジュールで動くだけのジョブは送らない" do
    assert_equal 0.0, sample(op: "queue.process", name: "FetcherLagMonitorJob")
  end

  test "transaction_context が無くても落ちない" do
    assert_equal SentryTracesSampler::JOB_RATE, SentryTracesSampler.call({})
  end
end
