require "test_helper"

class FeedFilters::RelativeUrlResolverTest < ActiveSupport::TestCase
  setup do
    @filter = FeedFilters::RelativeUrlResolver.new
    @channel = Channel.new(feed_url: "https://example.com/feed.xml")
  end

  test "applicable? returns true for path starting with /" do
    entry = OpenStruct.new(url: "/blog/article-123")
    assert @filter.applicable?(entry, @channel)
  end

  test "applicable? returns true for relative path without /" do
    entry = OpenStruct.new(url: "blog/article-123")
    assert @filter.applicable?(entry, @channel)
  end

  test "applicable? returns false for http URL" do
    entry = OpenStruct.new(url: "http://example.com/blog/article-123")
    assert_not @filter.applicable?(entry, @channel)
  end

  test "applicable? returns false for https URL" do
    entry = OpenStruct.new(url: "https://example.com/blog/article-123")
    assert_not @filter.applicable?(entry, @channel)
  end

  test "applicable? returns false when entry URL is blank" do
    entry = OpenStruct.new(url: nil)
    assert_not @filter.applicable?(entry, @channel)
  end

  test "apply converts path starting with /" do
    entry = OpenStruct.new(url: "/blog/article-123")
    filtered_entry = @filter.apply(entry, @channel)

    assert_equal "https://example.com/blog/article-123", filtered_entry.url
    assert @filter.applied
    assert_equal "/blog/article-123", @filter.details[:original_url]
    assert_equal "https://example.com/blog/article-123", @filter.details[:resolved_url]
  end

  test "apply preserves port if non-standard" do
    channel_with_port = Channel.new(feed_url: "https://example.com:8080/feed.xml")
    entry = OpenStruct.new(url: "/news/update")
    filtered_entry = @filter.apply(entry, channel_with_port)

    assert_equal "https://example.com:8080/news/update", filtered_entry.url
  end

  test "apply returns entry unchanged when URL is already absolute" do
    entry = OpenStruct.new(url: "https://example.com/blog/article-123")
    filtered_entry = @filter.apply(entry, @channel)

    assert_equal entry, filtered_entry
    assert_not @filter.applied
  end

  test "apply handles relative paths without leading slash" do
    entry = OpenStruct.new(url: "blog/article-123")
    filtered_entry = @filter.apply(entry, @channel)

    assert_equal "https://example.com/blog/article-123", filtered_entry.url
    assert @filter.applied
  end

  test "apply handles invalid URI gracefully" do
    @channel.feed_url = "not a valid url"
    entry = OpenStruct.new(url: "/blog/article-123")
    filtered_entry = @filter.apply(entry, @channel)

    # フォールバック処理で部分的なURLが生成される
    assert filtered_entry.url
  end
end
