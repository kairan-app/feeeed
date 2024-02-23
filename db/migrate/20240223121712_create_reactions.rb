class CreateReactions < ActiveRecord::Migration[7.1]
  def change
    create_table :reactions do |t|
      t.references :user, null: false, foreign_key: true
      t.references :item, null: false, foreign_key: true
      t.string :memo, limit: 300

      t.timestamps
    end

    add_index :reactions, %i[user_id item_id], unique: true
  end
end
