require "test_helper"

class ItemTest < ActiveSupport::TestCase
  describe "dependent destroy" do
    test "Itemを削除すると紐づくitem_skipsも削除される" do
      item = create(:item)
      user = create(:user)
      ItemSkip.create!(user: user, item: item)

      assert_difference("ItemSkip.count", -1) do
        item.destroy!
      end
    end
  end

  # #830: 先頭に見えない文字や改行の付いた image_url が保存され、image_tag がアセットとして探して 500 になっていた
  describe "image_url" do
    test "保存する前に、先頭の見えない文字や空白を取り除いて URL だけにする" do
      [
        "\uFFFC\uFFFC https://example.com/a.webp",
        "\r\n     \r\n https://example.com/a.webp",
        "https://example.com/a.webp \n"
      ].each do |value|
        item = create(:item, image_url: value)
        assert_equal "https://example.com/a.webp", item.image_url, value.inspect
      end
    end

    test "http(s) の URL が無ければ nil にする" do
      [ "/wp-content/a.png", "data:image/png;base64,iVBORw0KGgo=", "\uFFFC" ].each do |value|
        item = create(:item, image_url: value)
        assert_nil item.image_url, value.inspect
      end
    end
  end

  describe "image_url_or_placeholder" do
    test "http(s):// か // で始まる image_url はそのまま返す" do
      %w[https://example.com/a.png http://example.com/a.png //cdn.example.com/a.png].each do |value|
        item = create(:item)
        item.update_column(:image_url, value)
        assert_equal value, item.image_url_or_placeholder
      end
    end

    test "URL になっていない image_url が保存済みでも、プレースホルダを返す" do
      [ "\uFFFC\uFFFC https://example.com/a.webp", "\r\n https://example.com/a.png", "/wp-content/a.png" ].each do |value|
        item = create(:item)
        item.update_column(:image_url, value)
        assert item.image_url_or_placeholder.start_with?("https://placehold.jp/"), value.inspect
      end
    end
  end
end
