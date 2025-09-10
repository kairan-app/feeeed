require "test_helper"

class FeedNormalizerTest < ActiveSupport::TestCase
  test "applies pre-parse filters to fix Atom namespace" do
    xml_with_https = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <feed xmlns="https://www.w3.org/2005/Atom">
        <title>Test Feed</title>
        <link href="http://example.com" />
        <entry>
          <title>Test Entry</title>
          <link href="http://example.com/post/1" />
        </entry>
      </feed>
    XML

    result = FeedNormalizer.normalize_and_parse(xml_with_https, "http://example.com/feed.xml")

    assert_not_nil result[:feed]
    assert_includes result[:applied_filters], "AtomNamespaceFixer"
    assert_equal "Atom namespace URL protocol", result[:filter_details]["AtomNamespaceFixer"][:fixed]
  end

  test "applies post-parse filters to resolve relative URLs" do
    xml_with_relative_urls = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0">
        <channel>
          <title>Test Feed</title>
          <link>/</link>
          <item>
            <title>Test Item</title>
            <link>/post/1</link>
          </item>
          <item>
            <title>Another Item</title>
            <link>/post/2</link>
          </item>
        </channel>
      </rss>
    XML

    result = FeedNormalizer.normalize_and_parse(xml_with_relative_urls, "http://example.com/feed.xml")

    assert_not_nil result[:feed]
    assert_equal "http://example.com/", result[:feed].url
    assert_equal "http://example.com/post/1", result[:feed].entries[0].url
    assert_equal "http://example.com/post/2", result[:feed].entries[1].url

    assert_includes result[:applied_filters], "RelativeUrlResolver"
    assert_equal 3, result[:filter_details]["RelativeUrlResolver"][:converted_count]
  end

  test "applies multiple filters when needed" do
    # XMLにAtom名前空間の問題と相対URLの両方がある
    xml_with_multiple_issues = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <feed xmlns="https://www.w3.org/2005/Atom">
        <title>Test Feed</title>
        <link href="/" />
        <entry>
          <title>Test Entry</title>
          <link href="/post/1" />
        </entry>
      </feed>
    XML

    result = FeedNormalizer.normalize_and_parse(xml_with_multiple_issues, "http://example.com/feed.xml")

    assert_not_nil result[:feed]
    assert_equal "http://example.com/", result[:feed].url
    assert_equal "http://example.com/post/1", result[:feed].entries[0].url

    assert_includes result[:applied_filters], "AtomNamespaceFixer"
    assert_includes result[:applied_filters], "RelativeUrlResolver"
    assert_equal 2, result[:applied_filters].size
  end

  test "handles well-formed feed without applying unnecessary filters" do
    xml_wellformed = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0">
        <channel>
          <title>Test Feed</title>
          <link>http://example.com</link>
          <item>
            <title>Test Item</title>
            <link>http://example.com/post/1</link>
          </item>
        </channel>
      </rss>
    XML

    result = FeedNormalizer.normalize_and_parse(xml_wellformed, "http://example.com/feed.xml")

    assert_not_nil result[:feed]
    assert_empty result[:applied_filters]
    assert_empty result[:filter_details]
  end

  test "raises error for invalid XML that cannot be parsed" do
    invalid_xml = "This is not valid XML at all"

    assert_raises(Feedjira::NoParserAvailable) do
      FeedNormalizer.normalize_and_parse(invalid_xml, "http://example.com/feed.xml")
    end
  end

  test "preserves feed content while applying filters" do
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <feed xmlns="https://www.w3.org/2005/Atom">
        <title>My Blog</title>
        <link href="/blog" />
        <entry>
          <title>First Post</title>
          <link href="/blog/first-post" />
          <summary>This is my first post</summary>
        </entry>
      </feed>
    XML

    result = FeedNormalizer.normalize_and_parse(xml, "http://myblog.com/atom.xml")

    feed = result[:feed]
    assert_equal "My Blog", feed.title
    assert_equal "http://myblog.com/blog", feed.url
    assert_equal 1, feed.entries.size
    assert_equal "First Post", feed.entries[0].title
    assert_equal "http://myblog.com/blog/first-post", feed.entries[0].url
    assert_equal "This is my first post", feed.entries[0].summary
  end
end
