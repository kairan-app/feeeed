FactoryBot.define do
  factory :subscription_tag do
    association :user
    sequence(:name) { |n| "Tag #{n}" }
  end
end
