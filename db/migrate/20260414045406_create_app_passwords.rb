class CreateAppPasswords < ActiveRecord::Migration[8.1]
  def change
    create_table :app_passwords do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :token_last_4, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :app_passwords, :token_digest, unique: true
    add_index :app_passwords, [ :user_id, :revoked_at ]
  end
end
