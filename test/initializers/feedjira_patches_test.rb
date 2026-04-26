# Atomフィードの<content>内CDATAにxmlns:itunes宣言を含むコードスニペット
# (例: ポッドキャストの記事中のRSSサンプル)が混ざっていても、ITunesRSSパーサーで
# 誤って判定・パースされないことを確認するリグレッションテスト。
#
# かつてはモンキーパッチ(config/initializers/feedjira_patches.rb)で
# 修正していたが、feedjira 4.0.2で本家に取り込まれた。
# 将来のバージョンアップで再びregressionしないかを検知する保険として残す。
require "test_helper"

class FeedjiraPatchesTest < ActiveSupport::TestCase
  test "does not detect Atom feed with xmlns:itunes inside CDATA as ITunesRSS" do
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8" ?>
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title>Test Blog</title>
        <entry>
          <title>RSS feed example</title>
          <content type="html"><![CDATA[
            <pre><code>&lt;rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"&gt;</code></pre>
          ]]></content>
        </entry>
      </feed>
    XML

    assert_not Feedjira::Parser::ITunesRSS.able_to_parse?(xml)
  end

  test "still detects real iTunes RSS feed" do
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
        <channel>
          <title>My Podcast</title>
          <item>
            <title>Episode 1</title>
          </item>
        </channel>
      </rss>
    XML

    assert Feedjira::Parser::ITunesRSS.able_to_parse?(xml)
  end

  test "Feedjira.parse selects Atom parser for Atom feed with xmlns:itunes in CDATA" do
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8" ?>
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title>Test Blog</title>
        <link rel="alternate" href="https://example.com/" />
        <id>tag:example.com,2024:blog</id>
        <updated>2024-01-01T00:00:00Z</updated>
        <entry>
          <title>How to set up a podcast RSS feed</title>
          <link href="https://example.com/post/1" />
          <id>tag:example.com,2024:post-1</id>
          <published>2024-01-01T00:00:00Z</published>
          <content type="html"><![CDATA[
            <p>Here is an example RSS feed:</p>
            <pre><code>&lt;rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"&gt;</code></pre>
          ]]></content>
        </entry>
      </feed>
    XML

    feed = Feedjira.parse(xml)

    assert_instance_of Feedjira::Parser::Atom, feed
    assert_equal 1, feed.entries.size
    assert_equal "How to set up a podcast RSS feed", feed.entries.first.title
  end
end
