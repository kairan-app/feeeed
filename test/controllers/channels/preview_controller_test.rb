require "test_helper"

class Channels::PreviewControllerTest < ActionDispatch::IntegrationTest
  RSS = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Example Feed</title>
        <link>https://example.com/</link>
        <description>Example</description>
        <item>
          <title>Hello</title>
          <link>https://example.com/hello</link>
          <guid>https://example.com/hello</guid>
        </item>
      </channel>
    </rss>
  XML

  setup do
    sign_in(create(:user))
  end

  test "adds https:// to a URL without a scheme and shows the preview" do
    Httpc.expects(:get_with_redirect_info).with("https://example.com/feed")
      .returns({ body: RSS, final_url: "https://example.com/feed", redirected: false })

    get channel_preview_path, params: { url: "example.com/feed" }

    assert_response :success
    assert_includes response.body, "Example Feed"
  end

  test "redirects to the top with an alert when a URL without a scheme can't be fetched" do
    Httpc.expects(:get_with_redirect_info).with("https://example.com")
      .raises(Httpc::HTTPError.new("HTTP request failed with status 502", status: 502))

    get channel_preview_path, params: { url: "example.com" }

    assert_redirected_to root_path
    assert_equal "Couldn't fetch a feed from 'https://example.com'", flash[:alert]
  end

  test "redirects to the top with an alert when the URL contains a space" do
    Httpc.expects(:get_with_redirect_info).never

    get channel_preview_path, params: { url: "https://example.com/a https://example.com/b" }

    assert_redirected_to root_path
    assert_equal "'https://example.com/a https://example.com/b' is not a valid URL", flash[:alert]
  end

  test "redirects to the top with an alert when the URL is not http or https" do
    Httpc.expects(:get_with_redirect_info).never

    get channel_preview_path, params: { url: "ftp://example.com/feed" }

    assert_redirected_to root_path
    assert_equal "'ftp://example.com/feed' is not a valid URL", flash[:alert]
  end

  test "redirects to the top with an alert when fetching raises Httpc::HTTPError" do
    Httpc.expects(:get_with_redirect_info).with("https://example.com/feed")
      .raises(Httpc::HTTPError.new("HTTP request failed with status 500", status: 500))

    get channel_preview_path, params: { url: "https://example.com/feed" }

    assert_redirected_to root_path
    assert_equal "Couldn't fetch a feed from 'https://example.com/feed'", flash[:alert]
  end

  test "redirects to the top with an alert when the connection fails" do
    Httpc.expects(:get_with_redirect_info).with("https://example.com/feed")
      .raises(Faraday::ConnectionFailed.new("Connection refused"))

    get channel_preview_path, params: { url: "https://example.com/feed" }

    assert_redirected_to root_path
    assert_equal "Couldn't fetch a feed from 'https://example.com/feed'", flash[:alert]
  end
end
