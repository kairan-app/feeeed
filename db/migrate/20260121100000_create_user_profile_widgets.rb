class CreateUserProfileWidgets < ActiveRecord::Migration[8.1]
  def change
    create_table :user_profile_widgets do |t|
      t.references :user, null: false, foreign_key: true
      t.string :widget_type, null: false
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :user_profile_widgets, [ :user_id, :widget_type ], unique: true
    add_index :user_profile_widgets, [ :user_id, :position ]
  end
end
