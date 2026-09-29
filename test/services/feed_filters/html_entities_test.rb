require "test_helper"

class FeedFilters::HtmlEntitiesTest < ActiveSupport::TestCase
  test "WHATWG の名前付き文字参照を ; と & を除いた名前で引ける" do
    assert_equal " ", FeedFilters::HtmlEntities::TABLE["nbsp"]
    assert_equal "©", FeedFilters::HtmlEntities::TABLE["copy"]
    assert_equal "&", FeedFilters::HtmlEntities::TABLE["amp"]
    assert_nil FeedFilters::HtmlEntities::TABLE["nbsp;"]
    assert_operator FeedFilters::HtmlEntities::TABLE.size, :>, 2000
  end
end
