class CreatePaymentEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :payment_events do |t|
      t.references :payment, null: false, foreign_key: true
      t.string  :event_type,  null: false
      t.string  :from_status
      t.string  :to_status
      t.json    :payload
      t.string  :trace_id
      t.timestamps null: false
    end

    # immutable — no updates ever, so optimize for reads by payment
    add_index :payment_events, [:payment_id, :created_at]
  end
end
