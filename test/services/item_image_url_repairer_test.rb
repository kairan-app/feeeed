require "test_helper"

class ItemImageUrlRepairerTest < ActiveSupport::TestCase
  def item_with_image_url(value, url: "https://example.com/2024/01/post")
    item = create(:item, url: url)
    item.update_column(:image_url, value)
    item
  end

  test "値の中に URL があれば、URL の部分だけにする" do
    item = item_with_image_url("￼￼ https://example.com/a.webp")
    assert_equal "https://example.com/a.webp", ItemImageUrlRepairer.repaired_image_url(item)

    item = item_with_image_url("\r\n     \r\n https://example.com/a.png")
    assert_equal "https://example.com/a.png", ItemImageUrlRepairer.repaired_image_url(item)
  end

  test "/ で始まる相対パスは、Item の URL を基準に絶対 URL にする" do
    item = item_with_image_url("/wp-content/uploads/a.png")
    assert_equal "https://example.com/wp-content/uploads/a.png", ItemImageUrlRepairer.repaired_image_url(item)
  end

  test "URL にできないものは nil にする" do
    item = item_with_image_url("a.png")
    assert_nil ItemImageUrlRepairer.repaired_image_url(item)
  end

  test "直す対象は、http(s):// でも // でも始まらない image_url を持つ Item だけ" do
    broken = item_with_image_url("/wp-content/a.png")
    item_with_image_url("https://example.com/a.png")
    item_with_image_url("//cdn.example.com/a.png")
    create(:item)

    assert_equal [ broken.id ], ItemImageUrlRepairer.targets.pluck(:id)
  end

  test "apply: false では書き換えず、直す内容だけを出力する" do
    item = item_with_image_url("/wp-content/a.png")
    io = StringIO.new

    ItemImageUrlRepairer.run(apply: false, io: io)

    assert_equal "/wp-content/a.png", item.reload.image_url
    assert_includes io.string, %(item #{item.id} (channel #{item.channel_id}): "/wp-content/a.png" -> "https://example.com/wp-content/a.png")
    assert_includes io.string, "dry run"
  end

  test "apply: true で書き換え、updated_at は変えない" do
    fixed = item_with_image_url("￼ https://example.com/a.webp")
    dropped = item_with_image_url("a.png")
    updated_at = fixed.reload.updated_at

    ItemImageUrlRepairer.run(apply: true, io: StringIO.new)

    assert_equal "https://example.com/a.webp", fixed.reload.image_url
    assert_equal updated_at, fixed.updated_at
    assert_nil dropped.reload.image_url
    assert_empty ItemImageUrlRepairer.targets
  end
end
