require "test_helper"
require "ostruct"

class ChannelFetchAndSaveItemsTest < ActiveSupport::TestCase
  setup do
    @channel = Channel.create!(
      title: "Test Channel",
      feed_url: "https://example.com/feed.xml",
      site_url: "https://example.com"
    )

    # Sentry送信をスタブして実際に送らないようにする
    Sentry.stubs(:capture_exception)
  end

  private

  # テスト用のモックエントリを作成するヘルパー
  def build_mock_entry(overrides = {})
    defaults = {
      url: "https://example.com/entry1",
      entry_id: "entry-1",
      title: "Test Entry",
      published: 1.hour.ago,
      image: nil,
      itunes_image: nil,
      enclosure_url: nil,
      to_h: {}
    }
    OpenStruct.new(defaults.merge(overrides))
  end

  # fetch_and_normalize_feedのスタブ用ヘルパー
  def stub_feed_with_entries(entries, feed_class: Feedjira::Parser::Atom, redirected: false)
    feed = OpenStruct.new(
      entries: entries,
      title: "Test Feed",
      description: "Test Description",
      url: "https://example.com"
    )
    # feed_classのインスタンスとして振る舞えるようにする
    feed.define_singleton_method(:is_a?) { |klass| klass == feed_class || super(klass) }
    feed.define_singleton_method(:class) { feed_class }
    # case/when で使われるので === 対応が必要
    normalization_result = {
      feed: feed,
      applied_filters: [],
      filter_details: {},
      redirect_info: { redirected: redirected, final_url: @channel.feed_url }
    }
    Channel.stubs(:fetch_and_normalize_feed).returns(normalization_result)
    feed
  end

  # FEEEED-8T/B3: published が nil のエントリがあると sort_by(&:published) で
  # ArgumentError: comparison of Time with nil failed が発生する
  describe "エントリのpublishedがnilの場合 (FEEEED-8T)" do
    test "published が nil のエントリがあっても sort_by でクラッシュせず処理が継続される" do
      entries = [
        build_mock_entry(entry_id: "entry-1", url: "https://example.com/1", published: 1.hour.ago, title: "Entry 1"),
        build_mock_entry(entry_id: "entry-2", url: "https://example.com/2", published: nil, title: "Entry 2"),
        build_mock_entry(entry_id: "entry-3", url: "https://example.com/3", published: 2.hours.ago, title: "Entry 3")
      ]
      stub_feed_with_entries(entries)
      OpenGraph.stubs(:new).returns(OpenStruct.new(image: nil))

      @channel.fetch_and_save_items(:all)

      # published が nil のエントリは Item の validates :published_at, presence: true で保存失敗するが、
      # sort_by でクラッシュせず他のエントリは正常に保存される
      assert_equal 2, @channel.items.count
    end

    test "only_recent モードでも published が nil のエントリでクラッシュしない" do
      entries = [
        build_mock_entry(entry_id: "entry-1", url: "https://example.com/1", published: 1.hour.ago, title: "Entry 1"),
        build_mock_entry(entry_id: "entry-2", url: "https://example.com/2", published: nil, title: "Entry 2")
      ]
      stub_feed_with_entries(entries)
      OpenGraph.stubs(:new).returns(OpenStruct.new(image: nil))

      @channel.fetch_and_save_items(:only_recent)

      # sort_by でクラッシュしない、publishedがある1件のみ保存される
      assert_equal 1, @channel.items.count
    end
  end

  # FEEEED-B6: entry_id と url がともに nil だと guid が nil になり
  # guid.start_with?("yt:video:") で NoMethodError が発生する
  describe "エントリのguidがnilになる場合 (FEEEED-B6)" do
    test "entry_id も url も nil だが channel に site_url がある場合、Sentryにエラーが送られない" do
      # entry.url が nil でも channel.site_url にフォールバックするので url はblankにならない
      # しかし guid = entry.entry_id || entry.url で guid が nil になり
      # guid.start_with?("yt:video:") で NoMethodError が発生する
      entries = [
        build_mock_entry(entry_id: nil, url: nil, title: "No GUID Entry", published: 1.hour.ago),
        build_mock_entry(entry_id: "valid-entry", url: "https://example.com/valid", title: "Valid Entry", published: 2.hours.ago)
      ]
      stub_feed_with_entries(entries)
      OpenGraph.stubs(:new).returns(OpenStruct.new(image: nil))

      # channel に site_url があるので url のフォールバックが効く
      assert_equal "https://example.com", @channel.site_url

      # Sentryにエラーが送られないことを確認
      Sentry.unstub(:capture_exception)
      Sentry.expects(:capture_exception).never

      @channel.fetch_and_save_items(:all)

      # guidがnilのエントリはスキップされ、validなエントリのみ保存される
      assert_equal 1, @channel.items.count
    end

    test "entry_id が nil で url がある場合、guid に url が使われる" do
      entries = [
        build_mock_entry(entry_id: nil, url: "https://example.com/entry-no-id", title: "No ID Entry", published: 1.hour.ago)
      ]
      stub_feed_with_entries(entries)
      OpenGraph.stubs(:new).returns(OpenStruct.new(image: nil))

      @channel.fetch_and_save_items(:all)

      item = @channel.items.first
      assert_equal "https://example.com/entry-no-id", item.guid
    end
  end

  # FEEEED-8J: 不正な image_url を持つエントリがあっても Item 保存が失敗しない
  describe "不正なimage_urlの場合 (FEEEED-8J)" do
    test "HTTP/HTTPS でない image_url は nil に落とされて保存が成功する" do
      entries = [
        build_mock_entry(
          entry_id: "entry-bad-img",
          url: "https://example.com/1",
          title: "Bad Image Entry",
          published: 1.hour.ago,
          image: "data:image/png;base64,iVBORw0KGgo="
        )
      ]
      stub_feed_with_entries(entries)

      @channel.fetch_and_save_items(:all)

      item = @channel.items.first
      assert_not_nil item
      assert_nil item.image_url
    end

    test "有効な image_url はそのまま保存される" do
      entries = [
        build_mock_entry(
          entry_id: "entry-good-img",
          url: "https://example.com/1",
          title: "Good Image Entry",
          published: 1.hour.ago,
          image: "https://example.com/image.jpg"
        )
      ]
      stub_feed_with_entries(entries)

      @channel.fetch_and_save_items(:all)

      item = @channel.items.first
      assert_equal "https://example.com/image.jpg", item.image_url
    end
  end

  # FEEEED-87: fetch_and_save_items で一部のItemがバリデーションエラーで失敗した後に
  # mark_items_checked! を呼ぶと、association キャッシュに残った無効なItemが
  # Channel#update! に巻き込まれて "Items is invalid" が発生する
  describe "fetch_and_save_items 後の mark_items_checked! (FEEEED-87)" do
    test "一部のエントリが保存失敗しても mark_items_checked! が成功する" do
      entries = [
        build_mock_entry(entry_id: "good-entry", url: "https://example.com/good", published: 1.hour.ago, title: "Good Entry"),
        build_mock_entry(entry_id: "bad-entry", url: "https://example.com/bad", published: nil, title: "Bad Entry")
      ]
      stub_feed_with_entries(entries)
      OpenGraph.stubs(:new).returns(OpenStruct.new(image: nil))

      @channel.fetch_and_save_items(:all)

      assert_nothing_raised do
        @channel.mark_items_checked!
      end

      @channel.reload
      assert_not_nil @channel.last_items_checked_at
    end
  end

  # FEEEED-90: build_from が nil を返すフィード形式の場合、
  # save_from 内の parameters.merge! で NoMethodError が発生する
  describe "認識できないフィード形式の場合 (FEEEED-90)" do
    test "build_from が nil を返しても save_from がエラーにならない" do
      # 認識できないフィード形式をシミュレート
      unknown_feed_class = Class.new
      feed = OpenStruct.new(
        entries: [],
        title: "Unknown Feed",
        description: "Test",
        url: "https://example.com"
      )
      feed.define_singleton_method(:is_a?) { |klass| klass == unknown_feed_class || super(klass) }

      normalization_result = {
        feed: feed,
        applied_filters: [],
        filter_details: {},
        redirect_info: { redirected: false, final_url: @channel.feed_url }
      }

      Channel.stubs(:fetch_and_normalize_feed).returns(normalization_result)

      # save_from は update_info から呼ばれる
      # build_from が nil を返すので parameters.merge! でエラーにならないこと
      assert_nothing_raised do
        Channel.save_from(@channel.feed_url, normalization_result)
      end
    end
  end
end
