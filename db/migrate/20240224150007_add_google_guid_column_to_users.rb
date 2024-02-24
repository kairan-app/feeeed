class AddGoogleGuidColumnToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :google_guid, :string
  end
end
