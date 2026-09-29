require "test_helper"

class FeedFilters::PreParse::BareAmpersandEscaperTest < ActiveSupport::TestCase
  def run_filter(xml)
    filter = FeedFilters::PreParse::BareAmpersandEscaper.new
    out = filter.applicable?(xml) ? filter.apply(xml) : xml
    [ out, filter ]
  end

  test "文字参照になっていない & を本文と属性の両方で &amp; にする" do
    out, filter = run_filter(%(<a href="/?a=1&b=2">Q & A &</a>))
    assert_equal %(<a href="/?a=1&amp;b=2">Q &amp; A &amp;</a>), out
    assert_equal({ escaped: 3 }, filter.details)
  end

  test "文字参照の形になっているものはそのまま" do
    xml = "<a>&amp;&foo;&#65;&#x41;</a>"
    out, filter = run_filter(xml)
    assert_equal xml, out
    assert_not filter.applied
  end

  test "大文字の X の文字参照は XML では不正なのでエスケープする" do
    out, = run_filter("<a>&#X41;</a>")
    assert_equal "<a>&amp;#X41;</a>", out
  end

  test "CDATA の中の & はそのまま" do
    xml = "<a><![CDATA[a & b]]></a>"
    out, filter = run_filter(xml)
    assert_equal xml, out
    assert_not filter.applied
  end

  test "何も変わらない場合は、元のオブジェクトをそのまま返す (巨大な入力でのメモリ増幅を避ける)" do
    xml = "<a>&amp;&foo;&#65;&#x41;</a>"
    out, filter = run_filter(xml)
    assert_same xml, out
    assert_not filter.applied
  end
end
