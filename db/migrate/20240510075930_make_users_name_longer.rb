class MakeUsersNameLonger < ActiveRecord::Migration[7.1]
  def change
    change_column :users, :name, :string, limit: 30
  end
end
