class CreateChannelLeases < ActiveRecord::Migration[8.1]
  def change
    # fetcher (Rust) に貸し出し中のチャンネル。1チャンネル・1ホストにつき同時に1つまで (一意制約で守る)
    create_table :channel_leases, id: false do |t|
      t.references :channel, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :host, null: false
      t.string :worker_name, null: false
      t.datetime :leased_until, null: false
      t.datetime :created_at, null: false
    end
    add_index :channel_leases, :host, unique: true
  end
end
