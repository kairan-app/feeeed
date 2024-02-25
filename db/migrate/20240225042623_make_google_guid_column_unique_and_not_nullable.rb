class MakeGoogleGuidColumnUniqueAndNotNullable < ActiveRecord::Migration[7.1]
  def change
    change_column_null :users, :google_guid, false
    add_index :users, :google_guid, unique: true
  end
end
