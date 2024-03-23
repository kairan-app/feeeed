class AddModeColumnToNotificationWebhooksTable < ActiveRecord::Migration[7.1]
  def change
    add_column :notification_webhooks, :mode, :integer, null: false, default: 0
  end
end
