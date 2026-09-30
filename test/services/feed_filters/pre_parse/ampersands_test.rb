require "test_helper"

class FeedFilters::PreParse::AmpersandsTest < ActiveSupport::TestCase
  PATTERN = /&(?!(?:[A-Za-z][A-Za-z0-9]*|#[0-9]+|#x[0-9A-Fa-f]+);)/
  NAMED = /&([A-Za-z][A-Za-z0-9]*);/

  INPUTS = [
    "",
    "no ampersand",
    "&",
    "&&",
    "a & b",
    "&amp;&&amp;",
    "&amp",
    "日本語&nbsp;と & と&#65;",
    "末尾の&",
    "&foo;&bar;&#x41;&#X41;"
  ].freeze

  test "gsub は String#gsub と同じ結果になる" do
    INPUTS.each do |text|
      assert_equal text.gsub(PATTERN, "[amp]"), FeedFilters::PreParse::Ampersands.gsub(text, PATTERN) { "[amp]" }, text
      assert_equal text.gsub(NAMED) { "[#{$1}]" },
                   FeedFilters::PreParse::Ampersands.gsub(text, NAMED) { "[#{_1[1]}]" }, text
    end
  end

  test "gsub のブロックには一致した中身を読める StringScanner を渡す" do
    matched = []
    FeedFilters::PreParse::Ampersands.gsub("a &nbsp; b &copy;", NAMED) { matched << _1.matched; "" }
    assert_equal %w[&nbsp; &copy;], matched
  end

  test "一致が無ければ元のオブジェクトをそのまま返す" do
    text = "&amp;&#65;"
    assert_same text, FeedFilters::PreParse::Ampersands.gsub(text, PATTERN) { "x" }
  end

  test "match? は String#match? と同じ結果になる" do
    INPUTS.each do |text|
      assert_equal text.match?(NAMED), FeedFilters::PreParse::Ampersands.match?(text, NAMED), text
    end
  end
end
