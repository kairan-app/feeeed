require "test_helper"

class FeedFilters::PostParse::RelativeUrlResolverTest < ActiveSupport::TestCase
  setup do
    @filter = FeedFilters::PostParse::RelativeUrlResolver.new
  end

  test "detects feed with relative URLs in entries" do
    feed = create_mock_feed(
      feed_url: "http://example.com",
      entries: [
        { url: "/post/1", title: "Post 1" },
        { url: "http://example.com/post/2", title: "Post 2" }
      ]
    )

    assert @filter.applicable?(feed, { feed_url: "http://example.com/feed.xml" })
  end

  test "does not detect feed with all absolute URLs" do
    feed = create_mock_feed(
      feed_url: "http://example.com",
      entries: [
        { url: "http://example.com/post/1", title: "Post 1" },
        { url: "https://example.com/post/2", title: "Post 2" }
      ]
    )

    assert_not @filter.applicable?(feed, { feed_url: "http://example.com/feed.xml" })
  end

  test "resolves relative URLs in feed and entries" do
    feed = create_mock_feed(
      feed_url: "/",
      entries: [
        { url: "/post/1", title: "Post 1" },
        { url: "post/2", title: "Post 2" },
        { url: "http://example.com/post/3", title: "Post 3" }
      ]
    )

    metadata = { feed_url: "http://example.com/feed.xml" }
    result = @filter.apply(feed, metadata)

    assert_equal "http://example.com/", result.url
    assert_equal "http://example.com/post/1", result.entries[0].url
    assert_equal "http://example.com/post/2", result.entries[1].url
    assert_equal "http://example.com/post/3", result.entries[2].url

    assert @filter.applied
    assert_equal 3, @filter.details[:converted_count]
    assert_equal "http://example.com", @filter.details[:base_url]
    assert_equal 3, @filter.details[:sample_urls].size
    assert_not @filter.details[:has_more]
  end

  test "handles URLs with port numbers" do
    feed = create_mock_feed(
      feed_url: "/",
      entries: [
        { url: "/post/1", title: "Post 1" }
      ]
    )

    metadata = { feed_url: "http://example.com:8080/feed.xml" }
    result = @filter.apply(feed, metadata)

    assert_equal "http://example.com:8080/", result.url
    assert_equal "http://example.com:8080/post/1", result.entries[0].url

    assert @filter.applied
    assert_equal "http://example.com:8080", @filter.details[:base_url]
  end

  test "handles HTTPS URLs correctly" do
    feed = create_mock_feed(
      feed_url: nil,
      entries: [
        { url: "/post/1", title: "Post 1" }
      ]
    )

    metadata = { feed_url: "https://secure.example.com/feed.xml" }
    result = @filter.apply(feed, metadata)

    assert_equal "https://secure.example.com/post/1", result.entries[0].url
    assert_equal "https://secure.example.com", @filter.details[:base_url]
  end

  test "limits sample URLs to 5 when many URLs are converted" do
    feed = create_mock_feed(
      feed_url: "/",
      entries: [
        { url: "/post/1", title: "Post 1" },
        { url: "/post/2", title: "Post 2" },
        { url: "/post/3", title: "Post 3" },
        { url: "/post/4", title: "Post 4" },
        { url: "/post/5", title: "Post 5" },
        { url: "/post/6", title: "Post 6" },
        { url: "/post/7", title: "Post 7" }
      ]
    )

    metadata = { feed_url: "http://example.com/feed.xml" }
    result = @filter.apply(feed, metadata)

    # All URLs should be converted
    assert_equal "http://example.com/post/7", result.entries[6].url

    # But only 5 should be in the sample
    assert @filter.applied
    assert_equal 8, @filter.details[:converted_count]  # feed URL + 7 entries
    assert_equal 5, @filter.details[:sample_urls].size
    assert @filter.details[:has_more]
  end

  test "handles empty or nil URLs gracefully" do
    feed = create_mock_feed(
      feed_url: nil,
      entries: [
        { url: nil, title: "No URL" },
        { url: "", title: "Empty URL" },
        { url: "/valid", title: "Valid" }
      ]
    )

    metadata = { feed_url: "http://example.com/feed.xml" }
    result = @filter.apply(feed, metadata)

    assert_nil result.entries[0].url
    assert_equal "", result.entries[1].url
    assert_equal "http://example.com/valid", result.entries[2].url

    assert @filter.applied
    assert_equal 1, @filter.details[:converted_count]
  end

  private

  def create_mock_feed(feed_url:, entries:)
    feed = OpenStruct.new(url: feed_url, entries: [])

    entries.each do |entry_data|
      entry = OpenStruct.new(entry_data)
      feed.entries << entry
    end

    feed
  end
end
