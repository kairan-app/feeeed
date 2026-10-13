require "test_helper"

class ChannelsSearchTest < ActionDispatch::IntegrationTest
  test "大文字小文字を区別せずにチャンネルを探せる" do
    create(:channel, title: "Ruby Weekly")
    create(:channel, title: "Python Weekly")

    get channels_path(channel_q: { title_or_description_or_site_url_or_feed_url_i_cont: "ruby" })

    assert_response :success
    assert_match(/Ruby Weekly/, response.body)
    assert_no_match(/Python Weekly/, response.body)
  end

  test "検索フォームは大文字小文字を区別しない述語で送る" do
    get channels_path

    assert_select "input[name='channel_q[title_or_description_or_site_url_or_feed_url_i_cont]']"
  end
end
