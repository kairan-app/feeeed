class CreateSubscriptionTags < ActiveRecord::Migration[8.1]
  def change
    create_table :subscription_tags do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false, limit: 32
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :subscription_tags, [:user_id, :name], unique: true
    add_index :subscription_tags, [:user_id, :position]
  end
end
