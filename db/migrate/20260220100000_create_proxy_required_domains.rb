class CreateProxyRequiredDomains < ActiveRecord::Migration[8.0]
  def change
    create_table :proxy_required_domains do |t|
      t.string :domain, null: false
      t.timestamps
    end

    add_index :proxy_required_domains, :domain, unique: true
  end
end
