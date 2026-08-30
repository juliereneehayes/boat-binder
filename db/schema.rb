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

ActiveRecord::Schema[8.1].define(version: 2026_08_30_100000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "account_export_requests", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "decided_at"
    t.bigint "decided_by_id"
    t.datetime "fulfilled_at"
    t.bigint "fulfilled_by_id"
    t.string "lifecycle_context", null: false
    t.datetime "recipient_verified_at"
    t.bigint "recipient_verified_by_id"
    t.bigint "requester_id", null: false
    t.datetime "scope_verified_at"
    t.bigint "scope_verified_by_id"
    t.string "status", default: "requested", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "idx_account_export_requests_one_open_per_account", unique: true, where: "((status)::text = ANY ((ARRAY['requested'::character varying, 'approved'::character varying])::text[]))"
    t.index ["account_id"], name: "index_account_export_requests_on_account_id"
    t.index ["decided_by_id"], name: "index_account_export_requests_on_decided_by_id"
    t.index ["fulfilled_by_id"], name: "index_account_export_requests_on_fulfilled_by_id"
    t.index ["recipient_verified_by_id"], name: "index_account_export_requests_on_recipient_verified_by_id"
    t.index ["requester_id"], name: "index_account_export_requests_on_requester_id"
    t.index ["scope_verified_by_id"], name: "index_account_export_requests_on_scope_verified_by_id"
    t.check_constraint "lifecycle_context::text = ANY (ARRAY['scheduled_cancellation'::character varying, 'payment_recovery_pending'::character varying, 'read_only_grace'::character varying, 'retained_inactive'::character varying, 'archive_eligible'::character varying]::text[])", name: "chk_account_export_requests_lifecycle_context"
    t.check_constraint "status::text = ANY (ARRAY['requested'::character varying, 'approved'::character varying, 'declined'::character varying, 'fulfilled'::character varying]::text[])", name: "chk_account_export_requests_status"
  end

  create_table "account_memberships", force: :cascade do |t|
    t.string "access_level", default: "read_only", null: false
    t.bigint "account_id", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["account_id"], name: "index_account_memberships_on_account_id"
    t.index ["active"], name: "index_account_memberships_on_active"
    t.index ["user_id", "account_id"], name: "index_account_memberships_on_user_id_and_account_id", unique: true
    t.index ["user_id"], name: "index_account_memberships_on_user_id"
    t.check_constraint "access_level::text = ANY (ARRAY['read_only'::character varying, 'editor'::character varying]::text[])", name: "chk_account_memberships_access_level"
  end

  create_table "accounts", force: :cascade do |t|
    t.string "account_type", default: "client", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.text "notes"
    t.string "time_zone", default: "America/Los_Angeles", null: false
    t.datetime "updated_at", null: false
    t.index ["account_type"], name: "index_accounts_on_account_type"
    t.index ["active"], name: "index_accounts_on_active"
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "asset_batteries", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.bigint "asset_id", null: false
    t.string "battery_type"
    t.datetime "created_at", null: false
    t.string "location"
    t.string "name", null: false
    t.text "notes"
    t.datetime "updated_at", null: false
    t.index ["asset_id", "active"], name: "index_asset_batteries_on_asset_id_and_active"
    t.index ["asset_id"], name: "index_asset_batteries_on_asset_id"
    t.index ["name"], name: "index_asset_batteries_on_name"
  end

  create_table "asset_engines", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.bigint "asset_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.text "notes"
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_asset_engines_on_active"
    t.index ["asset_id", "position"], name: "index_asset_engines_on_asset_id_and_position"
    t.index ["asset_id"], name: "index_asset_engines_on_asset_id"
  end

  create_table "assets", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.boolean "active", default: true, null: false
    t.string "asset_type", default: "vessel", null: false
    t.datetime "created_at", null: false
    t.decimal "length", precision: 6, scale: 2
    t.string "make"
    t.string "marina"
    t.string "model"
    t.string "name", null: false
    t.text "notes"
    t.string "registration_number"
    t.string "slip"
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.integer "year"
    t.index ["account_id", "asset_type", "name"], name: "index_assets_on_account_id_and_asset_type_and_name", unique: true
    t.index ["account_id", "registration_number"], name: "index_assets_on_account_id_and_registration_number", unique: true, where: "(registration_number IS NOT NULL)"
    t.index ["account_id"], name: "index_assets_on_account_id"
    t.index ["active"], name: "index_assets_on_active"
    t.index ["asset_type"], name: "index_assets_on_asset_type"
    t.index ["name"], name: "index_assets_on_name"
    t.index ["slug"], name: "index_assets_on_slug", unique: true
    t.check_constraint "asset_type::text = ANY (ARRAY['vessel'::character varying, 'home'::character varying, 'pet'::character varying, 'audit'::character varying, 'other'::character varying]::text[])", name: "chk_assets_asset_type"
    t.check_constraint "length IS NULL OR length > 0::numeric", name: "chk_assets_length_positive"
    t.check_constraint "year IS NULL OR year > 1900 AND year <= 2100", name: "chk_assets_year_reasonable"
  end

  create_table "billing_checkout_attempts", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.string "idempotency_key", null: false
    t.string "option_key", null: false
    t.string "replaces_external_subscription_id"
    t.string "status", default: "creating", null: false
    t.string "stripe_checkout_session_id"
    t.string "stripe_customer_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "idx_billing_checkout_attempts_one_active_per_account", unique: true, where: "((status)::text = ANY ((ARRAY['creating'::character varying, 'open'::character varying, 'replacing'::character varying, 'submitted'::character varying])::text[]))"
    t.index ["account_id"], name: "index_billing_checkout_attempts_on_account_id"
    t.index ["idempotency_key"], name: "index_billing_checkout_attempts_on_idempotency_key", unique: true
    t.index ["stripe_checkout_session_id"], name: "index_billing_checkout_attempts_on_stripe_checkout_session_id", unique: true, where: "(stripe_checkout_session_id IS NOT NULL)"
    t.index ["stripe_customer_id"], name: "index_billing_checkout_attempts_on_stripe_customer_id"
    t.check_constraint "replaces_external_subscription_id IS NULL OR replaces_external_subscription_id::text <> ''::text", name: "chk_billing_checkout_attempts_replacement_present"
    t.check_constraint "status::text = ANY (ARRAY['creating'::character varying, 'open'::character varying, 'replacing'::character varying, 'submitted'::character varying, 'completed'::character varying, 'canceled'::character varying, 'expired'::character varying, 'replaced'::character varying]::text[])", name: "chk_billing_checkout_attempts_status"
  end

  create_table "billing_webhook_events", force: :cascade do |t|
    t.string "api_version"
    t.datetime "created_at", null: false
    t.string "error_code"
    t.string "event_type", null: false
    t.string "external_event_id", null: false
    t.datetime "failed_at"
    t.boolean "livemode", default: false, null: false
    t.datetime "processed_at"
    t.string "provider", null: false
    t.string "status", default: "received", null: false
    t.datetime "updated_at", null: false
    t.index ["provider", "event_type"], name: "index_billing_webhook_events_on_provider_and_event_type"
    t.index ["provider", "external_event_id"], name: "index_billing_webhook_events_on_provider_and_external_event_id", unique: true
    t.index ["provider", "status"], name: "index_billing_webhook_events_on_provider_and_status"
    t.check_constraint "provider::text = ANY (ARRAY['local'::character varying, 'stripe'::character varying]::text[])", name: "chk_billing_webhook_events_provider"
    t.check_constraint "status::text = ANY (ARRAY['received'::character varying, 'processed'::character varying, 'ignored'::character varying, 'failed'::character varying]::text[])", name: "chk_billing_webhook_events_status"
  end

  create_table "binder_notes", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "asset_id"
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.date "due_date"
    t.string "note_type", default: "general", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_binder_notes_on_account_id"
    t.index ["asset_id"], name: "index_binder_notes_on_asset_id"
    t.index ["due_date"], name: "index_binder_notes_on_due_date"
    t.index ["note_type"], name: "index_binder_notes_on_note_type"
  end

  create_table "contacts", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.string "email"
    t.string "name", null: false
    t.string "phone"
    t.string "role"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_contacts_on_account_id"
  end

  create_table "documents", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "asset_id"
    t.datetime "created_at", null: false
    t.string "document_type", default: "other", null: false
    t.text "notes"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_documents_on_account_id"
    t.index ["asset_id"], name: "index_documents_on_asset_id"
    t.index ["document_type"], name: "index_documents_on_document_type"
  end

  create_table "reminders", force: :cascade do |t|
    t.bigint "asset_id", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.date "due_date", null: false
    t.string "reminder_type", default: "other", null: false
    t.string "status", default: "pending", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["asset_id"], name: "index_reminders_on_asset_id"
    t.index ["completed_at"], name: "index_reminders_on_completed_at"
    t.index ["status", "due_date"], name: "index_reminders_on_status_and_due_date"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'completed'::character varying]::text[])", name: "chk_reminders_status"
  end

  create_table "service_visit_battery_checks", force: :cascade do |t|
    t.bigint "asset_battery_id", null: false
    t.boolean "checked", default: false, null: false
    t.datetime "created_at", null: false
    t.text "notes"
    t.bigint "service_visit_id", null: false
    t.datetime "updated_at", null: false
    t.decimal "voltage", precision: 6, scale: 2
    t.index ["asset_battery_id"], name: "index_service_visit_battery_checks_on_asset_battery_id"
    t.index ["service_visit_id", "asset_battery_id"], name: "idx_visit_battery_checks_unique_battery", unique: true
    t.index ["service_visit_id"], name: "index_service_visit_battery_checks_on_service_visit_id"
    t.check_constraint "voltage IS NULL OR voltage >= 0::numeric", name: "chk_service_visit_battery_checks_voltage_non_negative"
  end

  create_table "service_visit_engine_readings", force: :cascade do |t|
    t.bigint "asset_engine_id", null: false
    t.datetime "created_at", null: false
    t.decimal "hours", precision: 8, scale: 1
    t.bigint "service_visit_id", null: false
    t.datetime "updated_at", null: false
    t.index ["asset_engine_id"], name: "index_service_visit_engine_readings_on_asset_engine_id"
    t.index ["service_visit_id", "asset_engine_id"], name: "idx_visit_engine_readings_unique_engine", unique: true
    t.index ["service_visit_id"], name: "index_service_visit_engine_readings_on_service_visit_id"
    t.check_constraint "hours IS NULL OR hours >= 0::numeric", name: "chk_service_visit_engine_readings_hours_non_negative"
  end

  create_table "service_visit_inspection_checks", force: :cascade do |t|
    t.boolean "checked", default: false, null: false
    t.datetime "created_at", null: false
    t.string "label", null: false
    t.text "notes"
    t.integer "position", default: 0, null: false
    t.bigint "service_visit_id", null: false
    t.datetime "updated_at", null: false
    t.index ["service_visit_id", "position"], name: "idx_visit_inspection_checks_position"
    t.index ["service_visit_id"], name: "index_service_visit_inspection_checks_on_service_visit_id"
  end

  create_table "service_visits", force: :cascade do |t|
    t.bigint "asset_id", null: false
    t.text "condition_notes"
    t.datetime "created_at", null: false
    t.decimal "engine_hours", precision: 8, scale: 1
    t.boolean "follow_up_needed", default: false, null: false
    t.text "follow_up_notes"
    t.string "location"
    t.bigint "performed_by_user_id", null: false
    t.text "summary"
    t.datetime "updated_at", null: false
    t.date "visit_date", null: false
    t.index ["asset_id"], name: "index_service_visits_on_asset_id"
    t.index ["performed_by_user_id"], name: "index_service_visits_on_performed_by_user_id"
    t.index ["visit_date"], name: "index_service_visits_on_visit_date"
    t.check_constraint "engine_hours IS NULL OR engine_hours >= 0::numeric", name: "chk_service_visits_engine_hours_non_negative"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", null: false
    t.bigint "channel_hash", null: false
    t.datetime "created_at", null: false
    t.binary "payload", null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.integer "byte_size", null: false
    t.datetime "created_at", null: false
    t.binary "key", null: false
    t.bigint "key_hash", null: false
    t.binary "value", null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "subscriptions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "cancel_at"
    t.boolean "cancel_at_period_end", default: false, null: false
    t.datetime "canceled_at"
    t.datetime "created_at", null: false
    t.datetime "current_period_ends_at"
    t.datetime "entitlement_ended_at"
    t.string "external_customer_id"
    t.string "external_subscription_id"
    t.datetime "last_synced_at"
    t.datetime "past_due_observed_at"
    t.string "plan", default: "legacy", null: false
    t.string "provider", default: "local", null: false
    t.string "status", default: "active", null: false
    t.datetime "trial_ends_at"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_subscriptions_on_account_id", unique: true
    t.index ["provider", "external_customer_id"], name: "index_subscriptions_on_provider_and_external_customer_id", where: "(external_customer_id IS NOT NULL)"
    t.index ["provider", "external_subscription_id"], name: "index_subscriptions_on_provider_and_external_subscription_id", unique: true, where: "(external_subscription_id IS NOT NULL)"
    t.check_constraint "plan::text = ANY (ARRAY['legacy'::character varying, 'self_managed'::character varying, 'starter'::character varying, 'professional'::character varying]::text[])", name: "chk_subscriptions_plan"
    t.check_constraint "provider::text = ANY (ARRAY['local'::character varying, 'stripe'::character varying]::text[])", name: "chk_subscriptions_provider"
    t.check_constraint "status::text = ANY (ARRAY['legacy'::character varying, 'trialing'::character varying, 'active'::character varying, 'past_due'::character varying, 'canceled'::character varying, 'expired'::character varying, 'suspended'::character varying]::text[])", name: "chk_subscriptions_status"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.datetime "invitation_accepted_at"
    t.datetime "invitation_sent_at"
    t.string "name"
    t.string "password_digest"
    t.string "role", default: "captain", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_users_on_active"
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "account_export_requests", "accounts"
  add_foreign_key "account_export_requests", "users", column: "decided_by_id"
  add_foreign_key "account_export_requests", "users", column: "fulfilled_by_id"
  add_foreign_key "account_export_requests", "users", column: "recipient_verified_by_id"
  add_foreign_key "account_export_requests", "users", column: "requester_id"
  add_foreign_key "account_export_requests", "users", column: "scope_verified_by_id"
  add_foreign_key "account_memberships", "accounts"
  add_foreign_key "account_memberships", "users"
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "asset_batteries", "assets"
  add_foreign_key "asset_engines", "assets"
  add_foreign_key "assets", "accounts"
  add_foreign_key "billing_checkout_attempts", "accounts"
  add_foreign_key "binder_notes", "accounts"
  add_foreign_key "binder_notes", "assets"
  add_foreign_key "contacts", "accounts"
  add_foreign_key "documents", "accounts"
  add_foreign_key "documents", "assets"
  add_foreign_key "reminders", "assets"
  add_foreign_key "service_visit_battery_checks", "asset_batteries"
  add_foreign_key "service_visit_battery_checks", "service_visits"
  add_foreign_key "service_visit_engine_readings", "asset_engines"
  add_foreign_key "service_visit_engine_readings", "service_visits"
  add_foreign_key "service_visit_inspection_checks", "service_visits"
  add_foreign_key "service_visits", "assets"
  add_foreign_key "service_visits", "users", column: "performed_by_user_id"
  add_foreign_key "sessions", "users"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "subscriptions", "accounts"
end
