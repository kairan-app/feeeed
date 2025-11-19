require "test_helper"

class HttpcTest < ActiveSupport::TestCase
  describe ".get_with_redirect_info" do
    test "リダイレクトが発生しない場合はredirected: falseを返す" do
      url = "https://example.com/feed.xml"
      body = "<xml>test</xml>"

      # Faradayのレスポンスをモック
      response = OpenStruct.new(
        status: 200,
        body: body,
        env: OpenStruct.new(url: url)
      )

      connection = mock("connection")
      connection.expects(:get).with(url).returns(response)
      Faraday.expects(:new).yields(mock("builder").tap do |builder|
        builder.expects(:use).with(FaradayMiddleware::FollowRedirects)
        builder.expects(:use).with(:cookie_jar)
        builder.expects(:adapter).with(Faraday.default_adapter)
      end).returns(connection)

      result = Httpc.get_with_redirect_info(url)

      assert_equal body, result[:body]
      assert_equal url, result[:final_url]
      assert_equal false, result[:redirected]
    end

    test "リダイレクトが発生した場合はredirected: trueと最終URLを返す" do
      original_url = "https://listen.style/p/juneboku-life/rss"
      final_url = "https://rss.listen.style/p/juneboku-life/rss"
      body = "<xml>test</xml>"

      # Faradayのレスポンスをモック（リダイレクト後のURL）
      response = OpenStruct.new(
        status: 200,
        body: body,
        env: OpenStruct.new(url: final_url)
      )

      connection = mock("connection")
      connection.expects(:get).with(original_url).returns(response)
      Faraday.expects(:new).yields(mock("builder").tap do |builder|
        builder.expects(:use).with(FaradayMiddleware::FollowRedirects)
        builder.expects(:use).with(:cookie_jar)
        builder.expects(:adapter).with(Faraday.default_adapter)
      end).returns(connection)

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

      connection = mock("connection")
      connection.expects(:get).with(url).returns(response)
      Faraday.expects(:new).yields(mock("builder").tap do |builder|
        builder.expects(:use).with(FaradayMiddleware::FollowRedirects)
        builder.expects(:use).with(:cookie_jar)
        builder.expects(:adapter).with(Faraday.default_adapter)
      end).returns(connection)

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

      connection = mock("connection")
      connection.expects(:get).with(url).returns(response)
      Faraday.expects(:new).yields(mock("builder").tap do |builder|
        builder.expects(:use).with(FaradayMiddleware::FollowRedirects)
        builder.expects(:use).with(:cookie_jar)
        builder.expects(:adapter).with(Faraday.default_adapter)
      end).returns(connection)

      result = Httpc.get(url)

      assert_equal body, result
    end
  end
end
