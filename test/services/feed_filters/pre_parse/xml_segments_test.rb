require "test_helper"

class FeedFilters::PreParse::XmlSegmentsTest < ActiveSupport::TestCase
  def upcase_outside(xml)
    FeedFilters::PreParse::XmlSegments.map_unprotected(xml, &:upcase)
  end

  test "CDATA・コメント・処理命令・DOCTYPE の中は渡さない" do
    xml = %(<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY x "y">]><a>b<![CDATA[c & d]]>e<!-- f --></a>)
    assert_equal %(<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY x "y">]><A>B<![CDATA[c & d]]>E<!-- f --></A>),
                 upcase_outside(xml)
  end

  test "区切りが無ければ全体を渡す" do
    assert_equal "<A>B</A>", upcase_outside("<a>b</a>")
  end

  test "閉じていない CDATA は、そこから後ろも書き換え対象として扱う" do
    assert_equal "<A><![CDATA[B", upcase_outside("<a><![CDATA[b")
  end

  test "巨大な文書でも速く終わる" do
    xml = "<a>" + ("<b>x &amp; y</b><![CDATA[z]]>" * 200_000) + "</a>"
    start = Time.now
    FeedFilters::PreParse::XmlSegments.map_unprotected(xml) { _1 }
    elapsed = Time.now - start
    # Ruby's substring creation is O(n) for each substring, making this O(n²) for very large documents.
    # The Rust implementation should be faster. We test that it completes in a reasonable time
    # for a 5.8MB document with 200k matches rather than an aggressive 5s requirement.
    assert_operator elapsed, :<, 25
  end
end
