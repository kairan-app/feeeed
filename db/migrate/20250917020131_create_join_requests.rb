class CreateJoinRequests < ActiveRecord::Migration[8.0]
  def change
    create_table :join_requests do |t|
      t.string :email, null: false
      t.string :icon_url
      t.string :comment, limit: 256
      t.references :approved_by, foreign_key: { to_table: :users }
      t.datetime :approved_at

      t.timestamps
    end

    add_index :join_requests, :email, unique: true
  end
end
