require "test_helper"

class FeedFilters::PreParse::LocalizedDateFixerTest < ActiveSupport::TestCase
  def run_filter(xml)
    filter = FeedFilters::PreParse::LocalizedDateFixer.new
    out = filter.applicable?(xml) ? filter.apply(xml) : xml
    [ out, filter ]
  end

  test "曜日と月が日本語の日時を英語の表記に直す" do
    xml = "<item><pubDate>金, 25 9月 2026 16:07:00 GMT</pubDate>" \
          "<dc:date>木, 1 10月 2026 01:02:03 GMT</dc:date>" \
          "<lastBuildDate>26 12月 2026</lastBuildDate>" \
          "<pubDate>月, 5 1月 2026 04:10:00 +0900</pubDate></item>"
    out, filter = run_filter(xml)
    assert_equal "<item><pubDate>25 Sep 2026 16:07:00 GMT</pubDate>" \
                 "<dc:date>1 Oct 2026 01:02:03 GMT</dc:date>" \
                 "<lastBuildDate>26 Dec 2026</lastBuildDate>" \
                 "<pubDate>5 Jan 2026 04:10:00 +0900</pubDate></item>", out
    assert_equal({ fixed: 4 }, filter.details)
  end

  test "英語の日時と、日時の要素以外の「月」には手を入れない" do
    xml = "<item><title>9月の予定 25 9月 2026</title><pubDate>Fri, 25 Sep 2026 16:07:00 GMT</pubDate></item>"
    out, filter = run_filter(xml)
    assert_equal xml, out
    assert_not filter.applied
  end

  test "13月のような存在しない月はそのまま" do
    xml = "<pubDate>1 13月 2026</pubDate>"
    out, filter = run_filter(xml)
    assert_equal xml, out
    assert_not filter.applied
  end

  test "直したあとの日時を DateTime.parse が正しく読める" do
    out, = run_filter("<pubDate>木, 1 10月 2026 01:02:03 GMT</pubDate>")
    date = out[%r{<pubDate>(.*)</pubDate>}, 1]
    assert_equal Time.utc(2026, 10, 1, 1, 2, 3), DateTime.parse(date).to_time.utc
  end
end
