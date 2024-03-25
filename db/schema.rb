# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2024_03_25_124754) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "channel_stoppers", force: :cascade do |t|
    t.bigint "channel_id", null: false
    t.string "reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_channel_stoppers_on_channel_id", unique: true
  end

  create_table "channels", force: :cascade do |t|
    t.string "title", limit: 256, null: false
    t.string "description", limit: 1024
    t.string "site_url", limit: 2083
    t.string "feed_url", limit: 2083, null: false
    t.string "image_url", limit: 2083
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["feed_url"], name: "index_channels_on_feed_url", unique: true
    t.index ["site_url"], name: "index_channels_on_site_url"
  end

  create_table "items", force: :cascade do |t|
    t.bigint "channel_id", null: false
    t.string "guid", limit: 256, null: false
    t.string "title", limit: 256, null: false
    t.string "url", limit: 2083, null: false
    t.string "image_url", limit: 2083
    t.datetime "published_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id", "guid"], name: "index_items_on_channel_id_and_guid", unique: true
    t.index ["channel_id"], name: "index_items_on_channel_id"
    t.index ["published_at"], name: "index_items_on_published_at"
  end

  create_table "notification_webhooks", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "url", limit: 2083, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "last_notified_at"
    t.integer "mode", default: 0, null: false
    t.index ["user_id"], name: "index_notification_webhooks_on_user_id"
  end

  create_table "ownerships", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "channel_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_ownerships_on_channel_id"
    t.index ["user_id", "channel_id"], name: "index_ownerships_on_user_id_and_channel_id", unique: true
    t.index ["user_id"], name: "index_ownerships_on_user_id"
  end

  create_table "pawprints", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "item_id", null: false
    t.string "memo", limit: 300
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["item_id"], name: "index_pawprints_on_item_id"
    t.index ["user_id", "item_id"], name: "index_pawprints_on_user_id_and_item_id", unique: true
    t.index ["user_id"], name: "index_pawprints_on_user_id"
  end

  create_table "subscriptions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "channel_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_subscriptions_on_channel_id"
    t.index ["user_id", "channel_id"], name: "index_subscriptions_on_user_id_and_channel_id", unique: true
    t.index ["user_id"], name: "index_subscriptions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "name", limit: 15, null: false
    t.string "email", limit: 254, null: false
    t.string "icon_url", limit: 2083, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "google_guid", null: false
    t.index ["google_guid"], name: "index_users_on_google_guid", unique: true
    t.index ["name"], name: "index_users_on_name", unique: true
  end

  add_foreign_key "channel_stoppers", "channels"
  add_foreign_key "items", "channels"
  add_foreign_key "notification_webhooks", "users"
  add_foreign_key "ownerships", "channels"
  add_foreign_key "ownerships", "users"
  add_foreign_key "pawprints", "items"
  add_foreign_key "pawprints", "users"
  add_foreign_key "subscriptions", "channels"
  add_foreign_key "subscriptions", "users"
end
