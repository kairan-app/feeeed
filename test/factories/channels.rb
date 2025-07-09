FactoryBot.define do
  factory :channel do
    sequence(:title) { |n| "Test Channel #{n}" }
    description { "A test channel description" }
    sequence(:feed_url) { |n| "https://example.com/feed#{n}.xml" }
    site_url { "https://example.com" }
    image_url { "https://example.com/image.jpg" }
    check_interval_hours { 1 }
  end
end
