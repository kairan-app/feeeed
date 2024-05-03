class MakeItemsGuidLonger < ActiveRecord::Migration[7.1]
  def change
    change_column :items, :guid, :string, limit: 2083
  end
end
