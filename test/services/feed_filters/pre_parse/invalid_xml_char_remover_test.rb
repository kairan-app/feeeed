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
end
