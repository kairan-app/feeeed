class CreateSubscriptions < ActiveRecord::Migration[7.1]
  def change
    create_table :subscriptions do |t|
      t.references :user, null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true

      t.timestamps
    end

    add_index :subscriptions, %i[user_id channel_id], unique: true
  end
end
