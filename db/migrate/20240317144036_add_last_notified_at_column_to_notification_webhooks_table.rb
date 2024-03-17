class AddLastNotifiedAtColumnToNotificationWebhooksTable < ActiveRecord::Migration[7.1]
  def change
    add_column :notification_webhooks, :last_notified_at, :datetime
  end
end
