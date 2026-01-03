class CreateSubscriptionTaggings < ActiveRecord::Migration[8.1]
  def change
    create_table :subscription_taggings do |t|
      t.references :subscription, null: false, foreign_key: true
      t.references :subscription_tag, null: false, foreign_key: true
      t.timestamps
    end
    add_index :subscription_taggings, [ :subscription_id, :subscription_tag_id ], unique: true, name: "idx_subscription_taggings_unique"
  end
end
