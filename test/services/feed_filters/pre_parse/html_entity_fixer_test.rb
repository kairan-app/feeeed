require "test_helper"

module FeedFilters
  module PreParse
    class HtmlEntityFixerTest < ActiveSupport::TestCase
      test "applicable? returns true when copyright tag contains HTML entities" do
        xml = <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <rss version="2.0">
            <channel>
              <title>Test Feed</title>
              <copyright>&copy; 2025 Example Corp</copyright>
            </channel>
          </rss>
        XML

        filter = HtmlEntityFixer.new
        assert filter.applicable?(xml)
      end

      test "applicable? returns true when generator tag contains HTML entities" do
        xml = <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <rss version="2.0">
            <channel>
              <title>Test Feed</title>
              <generator>WordPress &copy; &reg;</generator>
            </channel>
          </rss>
        XML

        filter = HtmlEntityFixer.new
        assert filter.applicable?(xml)
      end

      test "applicable? returns false when target tags do not contain HTML entities" do
        xml = <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <rss version="2.0">
            <channel>
              <title>Test Feed</title>
              <copyright>Copyright 2025</copyright>
            </channel>
          </rss>
        XML

        filter = HtmlEntityFixer.new
        assert_not filter.applicable?(xml)
      end

      test "applicable? returns false when HTML entities are only in non-target tags" do
        xml = <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <rss version="2.0">
            <channel>
              <title>Tech &amp; Design</title>
              <description>News &amp; Updates</description>
              <copyright>Copyright 2025</copyright>
            </channel>
          </rss>
        XML

        filter = HtmlEntityFixer.new
        assert_not filter.applicable?(xml)
      end

      test "applicable? returns false when target tags do not exist" do
        xml = <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <rss version="2.0">
            <channel>
              <title>Test &amp; Feed</title>
            </channel>
          </rss>
        XML

        filter = HtmlEntityFixer.new
        assert_not filter.applicable?(xml)
      end

      test "apply converts HTML entities in copyright tag" do
        xml = <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <rss version="2.0">
            <channel>
              <title>Test Feed</title>
              <copyright>&copy; 2025 Example Corp</copyright>
            </channel>
          </rss>
        XML

        filter = HtmlEntityFixer.new
        result = filter.apply(xml)

        assert filter.applied
        assert_equal [ "copyright" ], filter.details[:fixed_tags]
        # HTMLエンティティ(&copy;)が実際の文字(©)に変換される
        assert_includes result, "©"
        assert_not_includes result, "&copy;"
      end

      test "apply converts HTML entities in generator tag" do
        xml = <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <rss version="2.0">
            <channel>
              <title>Test Feed</title>
              <generator>WordPress &reg;</generator>
            </channel>
          </rss>
        XML

        filter = HtmlEntityFixer.new
        result = filter.apply(xml)

        assert filter.applied
        assert_equal [ "generator" ], filter.details[:fixed_tags]
        # HTMLエンティティ(&reg;)が実際の文字(®)に変換される
        assert_includes result, "®"
        assert_not_includes result, "&reg;"
      end

      test "apply preserves HTML entities in non-target tags" do
        xml = <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <rss version="2.0">
            <channel>
              <title>Tech &amp; Design</title>
              <copyright>&copy; 2025</copyright>
            </channel>
          </rss>
        XML

        filter = HtmlEntityFixer.new
        result = filter.apply(xml)

        # copyrightタグのエンティティは実際の文字に変換される
        assert_includes result, "©"
        # titleタグのエンティティは保持される
        assert_includes result, "Tech &amp; Design"
      end

      test "apply does not mark as applied when no changes are made" do
        xml = <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <rss version="2.0">
            <channel>
              <title>Test Feed</title>
              <copyright>Copyright 2025</copyright>
            </channel>
          </rss>
        XML

        filter = HtmlEntityFixer.new
        filter.apply(xml)

        assert_not filter.applied
        assert_empty filter.details
      end
    end
  end
end
