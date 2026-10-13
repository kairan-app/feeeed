require "test_helper"

class ChannelSimilarToTest < ActiveSupport::TestCase
  test "タイトルやサイトの URL が大文字小文字だけ違うチャンネルも見つける" do
    existing = create(:channel, title: "Ruby Weekly", site_url: "https://ruby.example.com")
    candidate = build(:channel, title: "ruby weekly", site_url: "https://RUBY.example.com")

    assert_includes Channel.similar_to(candidate), existing
  end
end
