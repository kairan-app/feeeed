FactoryBot.define do
  factory :channel_group do
    association :owner, factory: :user
    sequence(:name) { |n| "Test Channel Group #{n}" }
  end
end
