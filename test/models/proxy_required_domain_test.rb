require "test_helper"

class ProxyRequiredDomainTest < ActiveSupport::TestCase
  describe ".required?" do
    test "登録済みドメインのURLに対してtrueを返す" do
      ProxyRequiredDomain.create!(domain: "blocked.example.com")

      assert ProxyRequiredDomain.required?("https://blocked.example.com/feed.xml")
    end

    test "未登録ドメインのURLに対してfalseを返す" do
      assert_not ProxyRequiredDomain.required?("https://open.example.com/feed.xml")
    end

    test "無効なURLに対してfalseを返す" do
      assert_not ProxyRequiredDomain.required?("not a url")
    end
  end

  describe ".register!" do
    test "URLからドメインを抽出して登録する" do
      assert_difference "ProxyRequiredDomain.count", 1 do
        ProxyRequiredDomain.register!("https://blocked.example.com/feed.xml")
      end

      assert_equal "blocked.example.com", ProxyRequiredDomain.last.domain
    end

    test "同じドメインを二重登録しない" do
      ProxyRequiredDomain.register!("https://blocked.example.com/feed1.xml")

      assert_no_difference "ProxyRequiredDomain.count" do
        ProxyRequiredDomain.register!("https://blocked.example.com/feed2.xml")
      end
    end

    test "無効なURLに対してnilを返す" do
      assert_nil ProxyRequiredDomain.register!("not a url")
    end
  end

  describe "#recheck!" do
    test "直接アクセスで200が返ればレコードを削除する" do
      record = ProxyRequiredDomain.create!(domain: "unblocked.example.com")

      response = OpenStruct.new(status: 200, body: "OK")
      Httpc.expects(:direct_get).with("https://unblocked.example.com/").returns(response)

      assert_difference "ProxyRequiredDomain.count", -1 do
        record.recheck!
      end
    end

    test "Channelが存在する場合はそのfeed_urlでチェックする" do
      record = ProxyRequiredDomain.create!(domain: "blocked.example.com")
      channel = create(:channel, feed_url: "https://blocked.example.com/rss.xml")

      response = OpenStruct.new(status: 403, body: "Forbidden")
      Httpc.expects(:direct_get).with("https://blocked.example.com/rss.xml").returns(response)

      assert_no_difference "ProxyRequiredDomain.count" do
        record.recheck!
      end
    end

    test "直接アクセスで403が返ればレコードを残す" do
      record = ProxyRequiredDomain.create!(domain: "still-blocked.example.com")

      response = OpenStruct.new(status: 403, body: "Forbidden")
      Httpc.expects(:direct_get).with("https://still-blocked.example.com/").returns(response)

      assert_no_difference "ProxyRequiredDomain.count" do
        record.recheck!
      end
    end

    test "接続エラーでもレコードを残す" do
      record = ProxyRequiredDomain.create!(domain: "timeout.example.com")

      Httpc.expects(:direct_get).with("https://timeout.example.com/").raises(Faraday::ConnectionFailed.new("Connection refused"))

      assert_no_difference "ProxyRequiredDomain.count" do
        record.recheck!
      end
    end
  end

  describe "validations" do
    test "domainは必須" do
      record = ProxyRequiredDomain.new(domain: nil)
      assert_not record.valid?
      assert_includes record.errors[:domain], "can't be blank"
    end

    test "domainはユニーク" do
      ProxyRequiredDomain.create!(domain: "example.com")
      record = ProxyRequiredDomain.new(domain: "example.com")
      assert_not record.valid?
      assert_includes record.errors[:domain], "has already been taken"
    end
  end
end
