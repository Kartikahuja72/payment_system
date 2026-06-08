class CreateOutboxEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :outbox_events do |t|
      t.string  :aggregate_type,  null: false  # e.g. "Payment"
      t.bigint  :aggregate_id,    null: false
      t.string  :event_type,      null: false  # e.g. "payment.created"
      t.json    :payload,         null: false
      t.string  :status,          null: false, default: "pending"
      t.integer :retry_count,     null: false, default: 0
      t.datetime :published_at
      t.timestamps
    end

    add_index :outbox_events, :status
    add_index :outbox_events, [:aggregate_type, :aggregate_id]
  end
end
