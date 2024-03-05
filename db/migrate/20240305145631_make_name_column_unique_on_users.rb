class MakeNameColumnUniqueOnUsers < ActiveRecord::Migration[7.1]
  def change
    add_index :users, :name, unique: true
  end
end
