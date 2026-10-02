require "test_helper"

class Fetcher::ResultsTest < ActionDispatch::IntegrationTest
  include FetcherApiTestHelper
  include ActiveJob::TestHelper

  setup do
    ActiveJob::Base.queue_adapter = :test
    @old_tokens = ENV["FETCHER_TOKENS"]
    ENV["FETCHER_TOKENS"] = { "w1" => Digest::SHA256.hexdigest("secret-token"),
                              "w2" => Digest::SHA256.hexdigest("other-token") }.to_json
    @channel = create(:channel, feed_url: "https://a.example.com/feed.xml", last_items_checked_at: nil)
    ChannelLease.grant!(worker_name: "w1", max: 1, rollout_percent: 100)
    Sentry.stubs(:capture_message)
  end

  teardown do
    ENV["FETCHER_TOKENS"] = @old_tokens
  end

  def entry(guid)
    { guid:, title: "T #{guid}", url: "https://a.example.com/#{guid}", image_url: nil,
      published_at: "2026-09-25T00:00:00Z", data: { entry_id: guid } }
  end

  def post_result(body, token: "secret-token", channel_id: @channel.id)
    post "/fetcher/leases/#{channel_id}/result", params: body.to_json, headers: fetcher_headers(token)
  end

  def ok_body(entries)
    { fetched: true, error: nil, final_url: nil, register_proxy_urls: [], channel: nil,
      entries:, latest_guids: [] }
  end

  test "保存して件数を返し、lease を消してチェック済みにする" do
    post_result(ok_body([ entry("g1"), entry("g2") ]))

    assert_response :ok
    assert_equal({ "created" => 2, "skipped" => 0 }, response.parsed_body)
    assert_equal 2, @channel.items.count
    assert_not ChannelLease.exists?(channel_id: @channel.id)
    assert_not_nil @channel.reload.last_items_checked_at
  end

  test "取得に失敗した結果でもチェック済みにして lease を消す" do
    post_result({ fetched: false, error: { kind: "timeout", message: "timeout" } })

    assert_response :ok
    assert_not_nil @channel.reload.last_items_checked_at
    assert_not ChannelLease.exists?(channel_id: @channel.id)
  end

  test "他のワーカーの lease なら 409 で何も書かない" do
    post_result(ok_body([ entry("g1") ]), token: "other-token")

    assert_response :conflict
    assert_equal 0, @channel.items.count
    assert_nil @channel.reload.last_items_checked_at
    assert ChannelLease.exists?(channel_id: @channel.id)
  end

  test "期限切れの lease なら 409 で何も書かない" do
    ChannelLease.where(channel_id: @channel.id).update_all(leased_until: 1.minute.ago)

    post_result(ok_body([ entry("g1") ]))

    assert_response :conflict
    assert_equal 0, @channel.items.count
  end

  test "形が不正なら 422" do
    post_result({ fetched: "yes" })

    assert_response :unprocessable_content
  end

  test "entries が多ければ item の保存以降をジョブに回して 202 を返し、lease は残す" do
    entries = (1..201).map { entry("g#{_1}") }

    assert_enqueued_with(job: FetchResultApplyJob) do
      post_result(ok_body(entries))
    end

    assert_response :accepted
    assert_equal({ "queued" => 201 }, response.parsed_body)
    assert_equal 0, @channel.items.count
    assert ChannelLease.exists?(channel_id: @channel.id)
  end
end
