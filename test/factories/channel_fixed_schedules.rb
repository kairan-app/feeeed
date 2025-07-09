FactoryBot.define do
  factory :channel_fixed_schedule do
    channel
    day_of_week { 1 } # Monday
    hour { 10 }
  end
end
