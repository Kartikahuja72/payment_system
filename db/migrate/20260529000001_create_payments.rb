class CreatePayments < ActiveRecord::Migration[8.0]
  def change
    create_table :payments do |t|
      t.string   :order_id,            null: false
      t.bigint   :amount,              null: false  # stored in paise/cents, never floats
      t.string   :currency,            null: false, default: "INR"
      t.string   :status,              null: false, default: "created"
      t.string   :gateway
      t.string   :gateway_payment_id
      t.string   :idempotency_key,     null: false
      t.string   :payment_method,      null: false
      t.string   :trace_id
      t.integer  :lock_version,        null: false, default: 0
      t.timestamps
    end

    add_index :payments, :order_id,          unique: true
    add_index :payments, :idempotency_key,   unique: true
    add_index :payments, :gateway_payment_id, unique: true, where: "gateway_payment_id IS NOT NULL"
    add_index :payments, :status
    add_index :payments, :trace_id
  end
end
