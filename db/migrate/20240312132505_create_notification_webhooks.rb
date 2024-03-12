class CreateNotificationWebhooks < ActiveRecord::Migration[7.1]
  def change
    create_table :notification_webhooks do |t|
      t.references :user, null: false, foreign_key: true
      t.string :url, null: false, limit: 2083

      t.timestamps
    end
  end
end
