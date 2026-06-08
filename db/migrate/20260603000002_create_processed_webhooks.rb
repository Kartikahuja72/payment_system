class CreateProcessedWebhooks < ActiveRecord::Migration[8.0]
  def change
    create_table :processed_webhooks do |t|
      t.string :event_id, null: false
      t.string :source,   null: false   # "razorpay" or "stripe"
      t.timestamps
    end

    # Same event from same gateway must never be processed twice
    add_index :processed_webhooks, [:event_id, :source], unique: true
  end
end
