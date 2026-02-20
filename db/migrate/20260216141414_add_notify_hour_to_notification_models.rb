class AddNotifyHourToNotificationModels < ActiveRecord::Migration[8.0]
  def change
    add_column :notification_webhooks, :notify_hour, :integer, default: 0, null: false
    add_column :notification_emails, :notify_hour, :integer, default: 0, null: false
  end
end
