FactoryBot.define do
  factory :item do
    channel
    sequence(:guid) { |n| "guid-#{n}" }
    sequence(:title) { |n| "Test Item #{n}" }
    sequence(:url) { |n| "https://example.com/item#{n}" }
    published_at { Time.current }
  end
end
