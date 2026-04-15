FactoryBot.define do
  factory :app_password do
    user
    sequence(:name) { |n| "Test App Password #{n}" }
    token_digest { AppPassword.digest("rururu_#{SecureRandom.urlsafe_base64(32)}") }
    token_last_4 { "abcd" }
  end
end
