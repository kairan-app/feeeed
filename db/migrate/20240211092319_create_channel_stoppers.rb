class CreateChannelStoppers < ActiveRecord::Migration[7.1]
  def change
    create_table :channel_stoppers do |t|
      t.references :channel, null: false, foreign_key: true, index: { unique: true }
      t.string :reason

      t.timestamps
    end
  end
end
