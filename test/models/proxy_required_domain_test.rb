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
