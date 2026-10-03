require "test_helper"

class FetcherTokenTest < ActiveSupport::TestCase
  setup do
    @old = ENV["FETCHER_TOKENS"]
    ENV["FETCHER_TOKENS"] = { "w1" => Digest::SHA256.hexdigest("secret-1") }.to_json
  end

  teardown { ENV["FETCHER_TOKENS"] = @old }

  test "トークンの SHA-256 が一致するワーカー名を返す" do
    assert_equal "w1", FetcherToken.worker_name_for("secret-1")
  end

  test "一致しない・空のトークンは nil" do
    assert_nil FetcherToken.worker_name_for("secret-2")
    assert_nil FetcherToken.worker_name_for("")
    assert_nil FetcherToken.worker_name_for(nil)
  end

  test "FETCHER_TOKENS が壊れていたら誰も通さない" do
    ENV["FETCHER_TOKENS"] = "{not json"
    assert_nil FetcherToken.worker_name_for("secret-1")
  end
end
