require "test_helper"

class FetcherGoldenTest < ActiveSupport::TestCase
  FEED_URL = "https://example.com/golden/feed.xml"

  RSS = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>  Golden Feed  </title>
        <link>https://example.com/</link>
        <description>desc</description>
        <item>
          <title>Second</title>
          <link>https://example.com/2</link>
          <guid isPermaLink="false">g2</guid>
          <pubDate>Wed, 24 Sep 2026 11:00:00 +0900</pubDate>
          <description>summary 2</description>
        </item>
        <item>
          <title>First</title>
          <link>https://example.com/1</link>
          <guid isPermaLink="false">g1</guid>
          <pubDate>Wed, 24 Sep 2026 10:00:00 +0900</pubDate>
        </item>
        <item>
          <title>No date</title>
          <link>https://example.com/3</link>
          <guid isPermaLink="false">g3</guid>
        </item>
      </channel>
    </rss>
  XML

  test "Railsが保存する結果をJSONにできる" do
    result = FetcherGolden.build(body: RSS, feed_url: FEED_URL)

    assert_equal "rss", result[:format]
    assert_equal({ "title" => "Golden Feed", "description" => "desc", "site_url" => "https://example.com/", "image_url" => nil }, result[:channel])
    assert_equal [], result[:applied_filters]
    assert_equal %w[g1 g2], result[:entries].map { _1[:guid] }
    assert_equal "2026-09-24T02:00:00Z", result[:entries].last[:published_at]
    assert_equal "summary 2", result[:entries].last[:data]["summary"]
    assert_equal [ { title: "No date", reason: "validation_failed" } ], result[:skipped]
  end

  test "DBに何も残さない" do
    assert_no_difference -> { Channel.count } do
      assert_no_difference -> { Item.count } do
        FetcherGolden.build(body: RSS, feed_url: FEED_URL)
      end
    end
  end

  test "差し替えたメソッドを元に戻す" do
    original = Httpc.method(:get_with_redirect_info)
    FetcherGolden.build(body: RSS, feed_url: FEED_URL)
    assert_equal original.owner, Httpc.method(:get_with_redirect_info).owner
    assert_not Channel.method_defined?(:sleep, false)
  end
end
