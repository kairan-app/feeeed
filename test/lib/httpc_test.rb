require "test_helper"

class HttpcTest < ActiveSupport::TestCase
  def stub_direct_get(url, response)
    connection = mock("connection")
    connection.expects(:get).with(url).returns(response)
    Faraday.expects(:new).yields(mock("builder").tap do |builder|
      builder.expects(:use).with(FaradayMiddleware::FollowRedirects)
      builder.expects(:use).with(:cookie_jar)
      builder.expects(:adapter).with(Faraday.default_adapter)
    end).returns(connection)
  end

  def stub_proxy_connection(expected_url, expected_secret, response)
    connection = mock("proxy_connection")
    connection.expects(:get).with("/").yields(mock("request").tap do |req|
      headers = {}
      req.stubs(:headers).returns(headers)
    end).returns(response)
    Faraday.expects(:new).with(url: ENV["FEED_PROXY_URL"]).yields(mock("builder").tap do |builder|
      builder.expects(:adapter).with(Faraday.default_adapter)
    end).returns(connection)
  end

  describe ".get_with_redirect_info" do
    test "リダイレクトが発生しない場合はredirected: falseを返す" do
      url = "https://example.com/feed.xml"
      body = "<xml>test</xml>"

      response = OpenStruct.new(
        status: 200,
        body: body,
        env: OpenStruct.new(url: url)
      )

      stub_direct_get(url, response)

      result = Httpc.get_with_redirect_info(url)

      assert_equal body, result[:body]
      assert_equal url, result[:final_url]
      assert_equal false, result[:redirected]
    end

    test "リダイレクトが発生した場合はredirected: trueと最終URLを返す" do
      original_url = "https://listen.style/p/juneboku-life/rss"
      final_url = "https://rss.listen.style/p/juneboku-life/rss"
      body = "<xml>test</xml>"

      response = OpenStruct.new(
        status: 200,
        body: body,
        env: OpenStruct.new(url: final_url)
      )

      stub_direct_get(original_url, response)

      result = Httpc.get_with_redirect_info(original_url)

      assert_equal body, result[:body]
      assert_equal final_url, result[:final_url]
      assert_equal true, result[:redirected]
    end

    test "HTTP エラーの場合は例外を投げる" do
      url = "https://example.com/feed.xml"

      response = OpenStruct.new(
        status: 404,
        body: "Not Found",
        env: OpenStruct.new(url: url)
      )

      stub_direct_get(url, response)

      assert_raises(RuntimeError) do
        Httpc.get_with_redirect_info(url)
      end
    end
  end

  describe ".get" do
    test "既存の動作を維持してbodyのみを返す" do
      url = "https://example.com/feed.xml"
      body = "<xml>test</xml>"

      response = OpenStruct.new(
        status: 200,
        body: body
      )

      stub_direct_get(url, response)

      result = Httpc.get(url)

      assert_equal body, result
    end
  end

  describe "proxy" do
    setup do
      ENV["FEED_PROXY_URL"] = "https://feeeed-proxy.example.workers.dev"
      ENV["FEED_PROXY_SECRET"] = "test-secret"
    end

    teardown do
      ENV.delete("FEED_PROXY_URL")
      ENV.delete("FEED_PROXY_SECRET")
    end

    test ".proxy_available? は環境変数が設定されていればtrueを返す" do
      assert Httpc.proxy_available?
    end

    test ".proxy_available? は環境変数が未設定ならfalseを返す" do
      ENV.delete("FEED_PROXY_URL")
      assert_not Httpc.proxy_available?
    end

    describe "登録済みドメインへのリクエスト" do
      test "get は最初からプロキシ経由でリクエストする" do
        url = "https://blocked.example.com/feed.xml"
        body = "<xml>proxied</xml>"

        ProxyRequiredDomain.expects(:required?).with(url).returns(true)

        proxy_response = OpenStruct.new(status: 200, body: body)
        stub_proxy_connection(ENV["FEED_PROXY_URL"], ENV["FEED_PROXY_SECRET"], proxy_response)

        result = Httpc.get(url)
        assert_equal body, result
      end

      test "get_with_redirect_info はプロキシ経由でリクエストしX-Original-URLからリダイレクト情報を取得する" do
        url = "https://blocked.example.com/feed.xml"
        final_url = "https://blocked.example.com/new-feed.xml"
        body = "<xml>proxied</xml>"

        ProxyRequiredDomain.expects(:required?).with(url).returns(true)

        proxy_response = OpenStruct.new(
          status: 200,
          body: body,
          headers: { "X-Original-URL" => final_url }
        )
        stub_proxy_connection(ENV["FEED_PROXY_URL"], ENV["FEED_PROXY_SECRET"], proxy_response)

        result = Httpc.get_with_redirect_info(url)
        assert_equal body, result[:body]
        assert_equal final_url, result[:final_url]
        assert_equal true, result[:redirected]
      end
    end

    describe "直接アクセス失敗時のプロキシフォールバック" do
      test "接続エラー時にプロキシ経由でリトライしてドメインを登録する" do
        url = "https://new-blocked.example.com/feed.xml"
        body = "<xml>proxied</xml>"

        ProxyRequiredDomain.expects(:required?).with(url).returns(false)
        Httpc.expects(:direct_get).with(url).raises(Faraday::ConnectionFailed.new("Connection refused"))

        proxy_response = OpenStruct.new(status: 200, body: body)
        stub_proxy_connection(ENV["FEED_PROXY_URL"], ENV["FEED_PROXY_SECRET"], proxy_response)
        ProxyRequiredDomain.expects(:register!).with(url)

        result = Httpc.get(url)
        assert_equal body, result
      end

      test "403レスポンス時にget_with_redirect_infoがプロキシ経由でリトライしてドメインを登録する" do
        url = "https://new-blocked.example.com/feed.xml"
        body = "<xml>proxied</xml>"

        ProxyRequiredDomain.expects(:required?).with(url).returns(false)

        direct_response = OpenStruct.new(
          status: 403,
          body: "Forbidden",
          env: OpenStruct.new(url: url)
        )
        Httpc.expects(:direct_get).with(url).returns(direct_response)

        proxy_response = OpenStruct.new(
          status: 200,
          body: body,
          headers: { "X-Original-URL" => url }
        )
        stub_proxy_connection(ENV["FEED_PROXY_URL"], ENV["FEED_PROXY_SECRET"], proxy_response)
        ProxyRequiredDomain.expects(:register!).with(url)

        result = Httpc.get_with_redirect_info(url)
        assert_equal body, result[:body]
      end
    end
  end
end
