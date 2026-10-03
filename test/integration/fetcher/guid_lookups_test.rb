require "test_helper"

class Fetcher::GuidLookupsTest < ActionDispatch::IntegrationTest
  include FetcherApiTestHelper

  setup do
    @old_tokens = ENV["FETCHER_TOKENS"]
    ENV["FETCHER_TOKENS"] = { "w1" => Digest::SHA256.hexdigest("secret-token") }.to_json

    @channel = create(:channel)
    create(:item, channel: @channel, guid: "by-entry-id")
    create(:item, channel: @channel, guid: "https://example.com/by-url")
    create(:item, guid: "other-channel")
  end

  teardown do
    ENV["FETCHER_TOKENS"] = @old_tokens
  end

  test "entry_id と url のどちらも保存済みでないものだけ true" do
    entries = [
      { entry_id: "by-entry-id", url: "https://example.com/x" },
      { entry_id: nil, url: "https://example.com/by-url" },
      { entry_id: "new-one", url: "https://example.com/by-url" },
      { entry_id: "other-channel", url: nil },
      { entry_id: "new-two", url: "https://example.com/new" }
    ]

    post "/fetcher/channels/#{@channel.id}/guid_lookups", params: { entries: }.to_json, headers: fetcher_headers

    assert_response :ok
    assert_equal [ false, false, false, true, true ], response.parsed_body["new"]
  end

  test "body は Rails の params には読み込まない (自分で JSON.parse するので、2回解釈しない)" do
    post "/fetcher/channels/#{@channel.id}/guid_lookups", params: { entries: [] }.to_json, headers: fetcher_headers

    assert_response :ok
    assert_not request.params.key?("entries")
  end

  test "空の entries には空を返す" do
    post "/fetcher/channels/#{@channel.id}/guid_lookups", params: { entries: [] }.to_json, headers: fetcher_headers

    assert_response :ok
    assert_equal [], response.parsed_body["new"]
  end

  test "entries の形が不正なら 422" do
    post "/fetcher/channels/#{@channel.id}/guid_lookups", params: { entries: "x" }.to_json, headers: fetcher_headers
    assert_response :unprocessable_content

    post "/fetcher/channels/#{@channel.id}/guid_lookups", params: { entries: [ "x" ] }.to_json, headers: fetcher_headers
    assert_response :unprocessable_content

    post "/fetcher/channels/#{@channel.id}/guid_lookups", params: { entries: [ { entry_id: 1, url: nil } ] }.to_json, headers: fetcher_headers
    assert_response :unprocessable_content

    post "/fetcher/channels/#{@channel.id}/guid_lookups", params: { entries: [ { entry_id: nil, url: [ "x" ] } ] }.to_json, headers: fetcher_headers
    assert_response :unprocessable_content
  end
end
