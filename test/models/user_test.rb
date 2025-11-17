require "test_helper"

class UserTest < ActiveSupport::TestCase
  describe "generate_default_name" do
    test "generates default name from email" do
      test_cases = [
        # 2文字以上のローカル部分はそのまま使用
        { email: "alice@example.com", name: "alice" },
        { email: "bob@example.org", name: "bob" },
        { email: "test@gmail.com", name: "test" },

        # 1文字のローカル部分は@を.に置き換え
        { email: "a@example.com", name: "a.example.com" },
        { email: "x@example.org", name: "x.example.org" },
        { email: "z@test.jp", name: "z.test.jp" },

        # エッジケース
        { email: "ab@example.com", name: "ab" },
        { email: "verylongemailaddress@example.com", name: "verylongemailaddress" },
        { email: "a@sub.domain.example.com", name: "a.sub.domain.example.com" }
      ]

      test_cases.each do |test_case|
        assert_equal test_case[:name], User.generate_default_name(test_case[:email]),
                     "Expected #{test_case[:email]} to generate name '#{test_case[:name]}'"
      end
    end
  end
end
