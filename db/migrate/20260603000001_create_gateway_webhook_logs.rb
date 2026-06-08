class CreateGatewayWebhookLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :gateway_webhook_logs do |t|
      t.string   :source,      null: false              # "razorpay" or "stripe"
      t.string   :event_id,    null: false              # gateway's unique event ID
      t.string   :event_type,  null: false              # "payment.captured" etc.
      t.json     :payload,     null: false              # full raw body — never discard
      t.json     :headers                               # all HTTP headers received
      t.string   :signature                             # HMAC signature for audit
      t.datetime :received_at, null: false
      t.timestamps
    end

    add_index :gateway_webhook_logs, [:source, :event_id]
    add_index :gateway_webhook_logs, :received_at
  end
end
