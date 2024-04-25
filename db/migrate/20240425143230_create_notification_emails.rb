class CreateNotificationEmails < ActiveRecord::Migration[7.1]
  def change
    create_table :notification_emails do |t|
      t.references :user, null: false, foreign_key: true
      t.string :email, null: false
      t.integer :mode, null: false, default: 0
      t.datetime :last_notified_at
      t.string :verification_token, null: false
      t.datetime :verified_at

      t.timestamps
    end
  end
end
