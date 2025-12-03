FactoryBot.define do
  factory :user do
    sequence(:name) { |n| "testuser#{n}" }
    sequence(:email) { |n| "testuser#{n}@example.com" }
    sequence(:google_guid) { |n| "google-guid-#{n}" }
    icon_url { "https://example.com/icon.png" }
  end
end
