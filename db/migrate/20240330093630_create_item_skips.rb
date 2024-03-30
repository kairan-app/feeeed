class CreateItemSkips < ActiveRecord::Migration[7.1]
  def change
    create_table :item_skips do |t|
      t.references :item, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true

      t.timestamps
    end

    add_index :item_skips, %i[item_id user_id], unique: true
  end
end
