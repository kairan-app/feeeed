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

ActiveRecord::Schema[8.0].define(version: 2025_07_01_112401) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "channel_group_webhooks", force: :cascade do |t|
    t.bigint "channel_group_id", null: false
    t.string "url", limit: 2083, null: false
    t.datetime "last_notified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", default: 1, null: false
    t.index ["channel_group_id"], name: "index_channel_group_webhooks_on_channel_group_id"
    t.index ["user_id"], name: "index_channel_group_webhooks_on_user_id"
  end

  create_table "channel_groupings", force: :cascade do |t|
    t.bigint "channel_id", null: false
    t.bigint "channel_group_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_group_id"], name: "index_channel_groupings_on_channel_group_id"
    t.index ["channel_id", "channel_group_id"], name: "index_channel_groupings_on_channel_id_and_channel_group_id", unique: true
    t.index ["channel_id"], name: "index_channel_groupings_on_channel_id"
  end

  create_table "channel_groups", force: :cascade do |t|
    t.string "name", limit: 64, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "owner_id", default: 1, null: false
    t.index ["owner_id"], name: "index_channel_groups_on_owner_id"
  end

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
    t.integer "check_interval_hours", default: 1
    t.datetime "last_items_checked_at"
    t.index ["check_interval_hours"], name: "index_channels_on_check_interval_hours"
    t.index ["feed_url"], name: "index_channels_on_feed_url", unique: true
    t.index ["last_items_checked_at"], name: "index_channels_on_last_items_checked_at"
    t.index ["site_url"], name: "index_channels_on_site_url"
  end

  create_table "item_skips", force: :cascade do |t|
    t.bigint "item_id", null: false
    t.bigint "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["item_id", "user_id"], name: "index_item_skips_on_item_id_and_user_id", unique: true
    t.index ["item_id"], name: "index_item_skips_on_item_id"
    t.index ["user_id"], name: "index_item_skips_on_user_id"
  end

  create_table "items", force: :cascade do |t|
    t.bigint "channel_id", null: false
    t.string "guid", limit: 2083, null: false
    t.string "title", limit: 256, null: false
    t.string "url", limit: 2083, null: false
    t.string "image_url", limit: 2083
    t.datetime "published_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "data"
    t.index ["channel_id", "guid"], name: "index_items_on_channel_id_and_guid", unique: true
    t.index ["channel_id"], name: "index_items_on_channel_id"
    t.index ["created_at", "channel_id"], name: "index_items_on_created_at_and_channel_id"
    t.index ["published_at"], name: "index_items_on_published_at"
  end

  create_table "memberships", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "channel_group_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_group_id"], name: "index_memberships_on_channel_group_id"
    t.index ["user_id", "channel_group_id"], name: "index_memberships_on_user_id_and_channel_group_id", unique: true
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "notification_emails", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "email", null: false
    t.integer "mode", default: 0, null: false
    t.datetime "last_notified_at"
    t.string "verification_token", null: false
    t.datetime "verified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_notification_emails_on_user_id"
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
    t.index ["item_id", "user_id"], name: "index_pawprints_on_item_id_and_user_id"
    t.index ["item_id"], name: "index_pawprints_on_item_id"
    t.index ["user_id", "item_id"], name: "index_pawprints_on_user_id_and_item_id", unique: true
    t.index ["user_id"], name: "index_pawprints_on_user_id"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
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
    t.string "name", limit: 30, null: false
    t.string "email", limit: 254, null: false
    t.string "icon_url", limit: 2083, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "google_guid", null: false
    t.index ["google_guid"], name: "index_users_on_google_guid", unique: true
    t.index ["name"], name: "index_users_on_name", unique: true
  end

  add_foreign_key "channel_group_webhooks", "channel_groups"
  add_foreign_key "channel_group_webhooks", "users"
  add_foreign_key "channel_groupings", "channel_groups"
  add_foreign_key "channel_groupings", "channels"
  add_foreign_key "channel_groups", "users", column: "owner_id"
  add_foreign_key "channel_stoppers", "channels"
  add_foreign_key "item_skips", "items"
  add_foreign_key "item_skips", "users"
  add_foreign_key "items", "channels"
  add_foreign_key "memberships", "channel_groups"
  add_foreign_key "memberships", "users"
  add_foreign_key "notification_emails", "users"
  add_foreign_key "notification_webhooks", "users"
  add_foreign_key "ownerships", "channels"
  add_foreign_key "ownerships", "users"
  add_foreign_key "pawprints", "items"
  add_foreign_key "pawprints", "users"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "subscriptions", "channels"
  add_foreign_key "subscriptions", "users"
end
