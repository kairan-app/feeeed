# 既存の全ユーザーに owned_channels と subscribed_channels のウィジェットを追加する
#
# Usage:
#   rails runner scripts/oneshot/add_default_profile_widgets.rb

User.find_each do |user|
  user.profile_widgets.find_or_create_by!(widget_type: :owned_channels)
  user.profile_widgets.find_or_create_by!(widget_type: :subscribed_channels)
end

puts "Done. Added default profile widgets to #{User.count} users."
