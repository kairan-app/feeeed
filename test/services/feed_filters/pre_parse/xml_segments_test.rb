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

  test "巨大な文書 (ASCII) でも線形時間で処理する" do
    xml = "<a>" + ("<b>x &amp; y</b><![CDATA[z]]>" * 200_000) + "</a>"
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    FeedFilters::PreParse::XmlSegments.map_unprotected(xml) { _1 }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    assert_operator elapsed, :<, 5
  end

  test "巨大な文書 (日本語) でも線形時間で処理する" do
    xml = "<a>" + ("<b>日本語のテキスト &amp; y</b><![CDATA[z]]>" * 200_000) + "</a>"
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    FeedFilters::PreParse::XmlSegments.map_unprotected(xml) { _1 }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    assert_operator elapsed, :<, 5
  end
  # 以前の実装 (PROTECTED 正規表現で次の区切りを探す)。Rust 版もこの正規表現を使うので、結果が一致することを確かめる
  def reference_upcase_outside(xml)
    out = +""
    pos = 0
    scanner = StringScanner.new(xml)
    while scanner.skip_until(FeedFilters::PreParse::XmlSegments::PROTECTED)
      start = scanner.pos - scanner.matched.bytesize
      out << xml.byteslice(pos, start - pos).upcase << scanner.matched
      pos = scanner.pos
    end
    out << xml.byteslice(pos, xml.bytesize - pos).upcase
  end

  test "正規表現で区切りを探していた以前の実装と、境界の入力でも結果が同じ" do
    [
      "",
      "<a>b</a>",
      "<a><![CDATA[x]]><![CDATA[y]]>z</a>",
      "<a><!--c1--><!--c2-->d</a>",
      "<a><![CDATA[x <!-- y --> z]]>w</a>",
      "<a><![CDATA[x]]]]><![CDATA[>]]>w</a>",
      "<a><!-- unterminated <![CDATA[x]]> tail</a>",
      "<a><![CDATA[unterminated <!-- c --> tail</a>",
      "<a><!-->x-->y</a>",
      "<a><??>b<?pi x?>c<?unterminated</a>",
      "<a>b<!</a><!",
      "<a>b<?</a><?",
      %(<!DOCTYPE rss><a>x</a>),
      %(<!DOCTYPE rss [<!ENTITY x "y">]><a>x</a>),
      %(<!DOCTYPE rss [<!ENTITY x "]">]  ><a>x</a>),
      %(<!DOCTYPE rss [ unterminated <a>x</a>),
      %(<!DOCTYPEx><!doctype rss><a>x</a>),
      "<a>日本語<![CDATA[漢字]]>かな<!--注釈-->カナ</a>"
    ].each do |xml|
      assert_equal reference_upcase_outside(xml), upcase_outside(xml), xml
    end
  end

  # #825: 区切りの無い巨大な文書で、次の区切りを1回の正規表現で最後まで探すと Regexp.timeout を超える
  test "区切りの少ない巨大な文書でも Regexp.timeout を超えない" do
    xml = "<rss>" + ("<item><title>日本語のタイトル</title><description>本文 &amp; 説明</description></item>" * 50_000) +
          "<![CDATA[end]]></rss>"
    original = Regexp.timeout
    Regexp.timeout = 0.01
    begin
      out = FeedFilters::PreParse::XmlSegments.map_unprotected(xml) { _1 }
      assert_equal xml, out
    ensure
      Regexp.timeout = original
    end
  end
end
