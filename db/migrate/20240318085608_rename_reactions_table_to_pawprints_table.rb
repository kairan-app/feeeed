class RenameReactionsTableToPawprintsTable < ActiveRecord::Migration[7.1]
  def change
    rename_table :reactions, :pawprints
  end
end
