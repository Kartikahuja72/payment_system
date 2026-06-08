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

ActiveRecord::Schema[8.0].define(version: 2026_06_06_000004) do
  create_table "dead_letter_events", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "topic", null: false
    t.integer "partition", null: false
    t.bigint "offset", null: false
    t.json "payload", null: false
    t.text "error_message"
    t.string "consumer_class", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_dead_letter_events_on_created_at"
    t.index ["topic"], name: "index_dead_letter_events_on_topic"
  end

  create_table "gateway_webhook_logs", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "source", null: false
    t.string "event_id", null: false
    t.string "event_type", null: false
    t.json "payload", null: false
    t.json "headers"
    t.string "signature"
    t.datetime "received_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["received_at"], name: "index_gateway_webhook_logs_on_received_at"
    t.index ["source", "event_id"], name: "index_gateway_webhook_logs_on_source_and_event_id"
  end

  create_table "invoices", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "payment_id", null: false
    t.string "invoice_number", null: false
    t.bigint "amount", null: false
    t.string "currency", default: "INR", null: false
    t.string "status", default: "issued", null: false
    t.datetime "issued_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["invoice_number"], name: "index_invoices_on_invoice_number", unique: true
    t.index ["payment_id"], name: "index_invoices_on_payment_id", unique: true
  end

  create_table "ledger_entries", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "payment_id", null: false
    t.string "entry_type", null: false
    t.string "account_type", null: false
    t.string "direction", null: false
    t.bigint "amount", null: false
    t.string "currency", null: false
    t.string "reference_id", null: false
    t.string "trace_id"
    t.datetime "created_at", null: false
    t.index ["account_type"], name: "index_ledger_entries_on_account_type"
    t.index ["created_at"], name: "index_ledger_entries_on_created_at"
    t.index ["payment_id", "entry_type"], name: "index_ledger_entries_on_payment_id_and_entry_type"
    t.index ["payment_id"], name: "index_ledger_entries_on_payment_id"
    t.index ["reference_id"], name: "index_ledger_entries_on_reference_id", unique: true
  end

  create_table "outbox_events", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "aggregate_type", null: false
    t.bigint "aggregate_id", null: false
    t.string "event_type", null: false
    t.json "payload", null: false
    t.string "status", default: "pending", null: false
    t.integer "retry_count", default: 0, null: false
    t.datetime "published_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["aggregate_type", "aggregate_id"], name: "index_outbox_events_on_aggregate_type_and_aggregate_id"
    t.index ["status"], name: "index_outbox_events_on_status"
  end

  create_table "payment_events", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "payment_id", null: false
    t.string "event_type", null: false
    t.string "from_status"
    t.string "to_status"
    t.json "payload"
    t.string "trace_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["payment_id", "created_at"], name: "index_payment_events_on_payment_id_and_created_at"
    t.index ["payment_id"], name: "index_payment_events_on_payment_id"
  end

  create_table "payments", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "order_id", null: false
    t.bigint "amount", null: false
    t.string "currency", default: "INR", null: false
    t.string "status", default: "created", null: false
    t.string "gateway"
    t.string "gateway_payment_id"
    t.string "idempotency_key", null: false
    t.string "payment_method", null: false
    t.string "trace_id"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "email"
    t.index ["email"], name: "index_payments_on_email"
    t.index ["gateway_payment_id"], name: "index_payments_on_gateway_payment_id", unique: true
    t.index ["idempotency_key"], name: "index_payments_on_idempotency_key", unique: true
    t.index ["order_id"], name: "index_payments_on_order_id", unique: true
    t.index ["status"], name: "index_payments_on_status"
    t.index ["trace_id"], name: "index_payments_on_trace_id"
  end

  create_table "processed_events", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "event_id", null: false
    t.string "consumer", null: false
    t.string "topic", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_processed_events_on_created_at"
    t.index ["event_id", "consumer"], name: "index_processed_events_on_event_id_and_consumer", unique: true
  end

  create_table "processed_refunds", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "refund_id", null: false
    t.bigint "payment_id", null: false
    t.string "source", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["payment_id"], name: "index_processed_refunds_on_payment_id"
    t.index ["refund_id", "source"], name: "index_processed_refunds_on_refund_id_and_source", unique: true
  end

  create_table "processed_webhooks", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "event_id", null: false
    t.string "source", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id", "source"], name: "index_processed_webhooks_on_event_id_and_source", unique: true
  end

  create_table "reconciliation_mismatches", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "payment_id", null: false
    t.string "mismatch_type", null: false
    t.string "our_value", null: false
    t.string "gateway_value", null: false
    t.string "gateway", null: false
    t.string "status", default: "open", null: false
    t.text "notes"
    t.datetime "resolved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["mismatch_type"], name: "index_reconciliation_mismatches_on_mismatch_type"
    t.index ["payment_id", "mismatch_type"], name: "idx_on_payment_id_mismatch_type_5b1b274416"
    t.index ["payment_id"], name: "index_reconciliation_mismatches_on_payment_id"
    t.index ["status"], name: "index_reconciliation_mismatches_on_status"
  end

  create_table "reconciliation_reports", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "gateway", null: false
    t.date "report_date", null: false
    t.json "raw_data", null: false
    t.string "status", default: "pending", null: false
    t.datetime "fetched_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["gateway", "report_date"], name: "index_reconciliation_reports_on_gateway_and_report_date", unique: true
    t.index ["status"], name: "index_reconciliation_reports_on_status"
  end

  create_table "saga_transactions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "saga_id", null: false
    t.bigint "payment_id", null: false
    t.string "current_step", null: false
    t.string "status", default: "running", null: false
    t.json "steps_completed"
    t.json "metadata"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["payment_id"], name: "index_saga_transactions_on_payment_id", unique: true
    t.index ["saga_id"], name: "index_saga_transactions_on_saga_id", unique: true
    t.index ["status"], name: "index_saga_transactions_on_status"
  end

  add_foreign_key "ledger_entries", "payments"
  add_foreign_key "payment_events", "payments"
  add_foreign_key "reconciliation_mismatches", "payments"
end
