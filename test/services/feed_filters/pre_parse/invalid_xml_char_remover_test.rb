require "test_helper"

class FeedFilters::PreParse::InvalidXmlCharRemoverTest < ActiveSupport::TestCase
  def run_filter(xml)
    filter = FeedFilters::PreParse::InvalidXmlCharRemover.new
    out = filter.applicable?(xml) ? filter.apply(xml) : xml
    [ out, filter ]
  end

  test "XML で使えない生の文字を CDATA の中も含めて取り除く" do
    out, filter = run_filter("<a>x\u0008y<![CDATA[p\u0001q]]>￾</a>")
    assert_equal "<a>xy<![CDATA[pq]]></a>", out
    assert filter.applied
    assert_equal({ removed_chars: 3, removed_refs: 0 }, filter.details)
  end

  test "XML で使えない文字を指す文字参照を取り除く (CDATA の外だけ)" do
    out, filter = run_filter(%(<a b="&#x1F;">&#8;&#xD800;&#1114112;<![CDATA[&#8;]]></a>))
    assert_equal %(<a b=""><![CDATA[&#8;]]></a>), out
    assert_equal({ removed_chars: 0, removed_refs: 4 }, filter.details)
  end

  test "タブ・LF・CR と正しい文字参照はそのまま" do
    xml = "<a>\t\n\r&#9;&#xA;&#x3042;&#65;</a>"
    out, filter = run_filter(xml)
    assert_equal xml, out
    assert_not filter.applied
  end

  test "何も変わらない場合は、元のオブジェクトをそのまま返す (巨大な入力でのメモリ増幅を避ける)" do
    xml = "<a>\t\n\r&#9;&#xA;&#x3042;&#65;</a>"
    out, filter = run_filter(xml)
    assert_same xml, out
    assert_not filter.applied
  end
  test "U+FFFF と U+FFFE の生の文字も取り除き、その件数を数える" do
    out, filter = run_filter("<a>x\uFFFFy\uFFFEz\u001F</a>")
    assert_equal "<a>xyz</a>", out
    assert_equal({ removed_chars: 3, removed_refs: 0 }, filter.details)
  end

  # #825: 57MB のフィードで、文書全体に正規表現をかける判定が Regexp.timeout (1秒) を超えていた
  test "巨大な文書でも、文書全体を1回の正規表現で走査しない (Regexp.timeout を超えない)" do
    xml = "<rss>" + ("<item><title>日本語のタイトル</title><description>本文 &amp; 説明</description></item>" * 50_000) + "</rss>"
    original = Regexp.timeout
    Regexp.timeout = 0.01
    begin
      out, filter = run_filter(xml)
      assert_same xml, out
      assert_not filter.applied

      broken = xml.sub("本文", "本\u0008文")
      out, filter = run_filter(broken)
      assert_equal xml, out
      assert_equal({ removed_chars: 1, removed_refs: 0 }, filter.details)
    ensure
      Regexp.timeout = original
    end
  end
end
