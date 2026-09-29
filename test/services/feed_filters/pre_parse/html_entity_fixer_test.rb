require "test_helper"

class FeedFilters::PreParse::HtmlEntityFixerTest < ActiveSupport::TestCase
  def run_filter(xml)
    filter = FeedFilters::PreParse::HtmlEntityFixer.new
    out = filter.applicable?(xml) ? filter.apply(xml) : xml
    [ out, filter ]
  end

  test "HTML のエンティティを本文と属性の両方で数値の文字参照にする" do
    out, filter = run_filter(%(<a href="/?x=&nbsp;">&copy; 2026&hellip;</a>))
    assert_equal %(<a href="/?x=&#xA0;">&#xA9; 2026&#x2026;</a>), out
    assert_equal({ replaced: 3, unknown: 0 }, filter.details)
  end

  test "2文字に展開されるエンティティは2つの文字参照にする" do
    out, = run_filter("<a>&NotEqualTilde;</a>")
    assert_equal "<a>&#x2242;&#x338;</a>", out
  end

  test "表に無い名前は &amp;name; にして文字として残す" do
    out, filter = run_filter("<a>&foo; &bar;</a>")
    assert_equal "<a>&amp;foo; &amp;bar;</a>", out
    assert_equal({ replaced: 0, unknown: 2 }, filter.details)
  end

  test "XML の定義済みエンティティと数値の文字参照はそのまま" do
    xml = "<a>&amp;&lt;&gt;&quot;&apos;&#65;&#x41;</a>"
    out, filter = run_filter(xml)
    assert_equal xml, out
    assert_not filter.applied
  end

  test "CDATA とコメントの中は書き換えない" do
    xml = "<a><![CDATA[&nbsp;]]><!-- &copy; --></a>"
    out, filter = run_filter(xml)
    assert_equal xml, out
    assert_not filter.applied
  end

  test "独自のエンティティを宣言している文書には適用しない" do
    xml = %(<!DOCTYPE rss [<!ENTITY myent "x">]><a>&myent;&nbsp;</a>)
    assert_not FeedFilters::PreParse::HtmlEntityFixer.new.applicable?(xml)
  end

  test "これまでの対象だった channel の copyright も直る" do
    xml = "<rss><channel><copyright>&copy; 2025</copyright><title>t</title></channel></rss>"
    out, = run_filter(xml)
    assert_equal "<rss><channel><copyright>&#xA9; 2025</copyright><title>t</title></channel></rss>", out
  end
end
