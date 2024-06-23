class CreateMemberships < ActiveRecord::Migration[7.1]
  def change
    create_table :memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :channel_group, null: false, foreign_key: true

      t.timestamps
    end

    add_index :memberships, %i[user_id channel_group_id], unique: true
  end
end
