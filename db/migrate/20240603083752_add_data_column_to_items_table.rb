class AddDataColumnToItemsTable < ActiveRecord::Migration[7.1]
  def change
    add_column :items, :data, :jsonb
  end
end
