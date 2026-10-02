require "test_helper"

class Fetcher::LeasesTest < ActionDispatch::IntegrationTest
  include FetcherApiTestHelper

  setup do
    @old_tokens = ENV["FETCHER_TOKENS"]
    ENV["FETCHER_TOKENS"] = { "w1" => Digest::SHA256.hexdigest("secret-token") }.to_json
    @old_rollout = ENV["ROLLOUT_PERCENT"]
    ENV["ROLLOUT_PERCENT"] = "100"
  end

  teardown do
    ENV["ROLLOUT_PERCENT"] = @old_rollout
    ENV["FETCHER_TOKENS"] = @old_tokens
  end

  test "トークンが無い・違うと 401" do
    post "/fetcher/leases", params: { max: 1 }.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized

    post "/fetcher/leases", params: { max: 1 }.to_json, headers: fetcher_headers("wrong")
    assert_response :unauthorized
  end

  test "貸し出したチャンネルと proxy の要るドメインを返す" do
    channel = create(:channel, feed_url: "https://a.example.com/feed.xml", site_url: "https://a.example.com/", last_items_checked_at: nil)
    ProxyRequiredDomain.create!(domain: "A.Example.com")

    post "/fetcher/leases", params: { max: 8 }.to_json, headers: fetcher_headers

    assert_response :ok
    body = response.parsed_body
    assert_equal [ { "channel_id" => channel.id, "feed_url" => channel.feed_url,
                     "site_url" => "https://a.example.com/", "use_proxy" => true } ], body["leases"]
    assert_equal [ "a.example.com" ], body["proxy_required_domains"]
    assert_equal "w1", ChannelLease.find(channel.id).worker_name
  end

  test "ROLLOUT_PERCENT が 0 なら空" do
    ENV["ROLLOUT_PERCENT"] = "0"
    create(:channel, feed_url: "https://a.example.com/feed.xml", last_items_checked_at: nil)

    post "/fetcher/leases", params: { max: 8 }.to_json, headers: fetcher_headers

    assert_response :ok
    assert_empty response.parsed_body["leases"]
  end

  test "max が範囲外・JSON でない body は 422" do
    post "/fetcher/leases", params: { max: 0 }.to_json, headers: fetcher_headers
    assert_response :unprocessable_content

    post "/fetcher/leases", params: { max: 33 }.to_json, headers: fetcher_headers
    assert_response :unprocessable_content

    post "/fetcher/leases", params: "not json", headers: fetcher_headers
    assert_response :unprocessable_content

    post "/fetcher/leases", params: [ 1 ].to_json, headers: fetcher_headers
    assert_response :unprocessable_content
  end
end
