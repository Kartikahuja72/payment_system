class CreateProcessedEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :processed_events do |t|
      t.string  :event_id,     null: false
      t.string  :consumer,     null: false  # which consumer processed it e.g. "PaymentCreatedConsumer"
      t.string  :topic,        null: false
      t.timestamps
    end

    # Uniqueness is per consumer — same event_id can be processed by different consumers
    add_index :processed_events, [:event_id, :consumer], unique: true
    add_index :processed_events, :created_at
  end
end
