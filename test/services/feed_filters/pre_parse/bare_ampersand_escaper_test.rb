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

  # #827: 文字参照の & が大量にあって、エスケープする & が無い (または少ない) 巨大な文書では、
  # 次の一致を探す1回の検索が文書の最後まで走り、Regexp.timeout を超える
  test "文字参照の多い巨大な文書でも Regexp.timeout を超えない" do
    xml = "<rss>" + ("<item><title>日本語 &amp; タイトル&#65;</title></item>" * 50_000) + "<link>/?a=1&b=2</link></rss>"
    expected = xml.sub("&b=", "&amp;b=")
    original = Regexp.timeout
    Regexp.timeout = 0.01
    begin
      out, filter = run_filter(xml)
      assert_equal expected, out
      assert_equal({ escaped: 1 }, filter.details)
    ensure
      Regexp.timeout = original
    end
  end
end
