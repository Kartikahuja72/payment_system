class CreateProcessedRefunds < ActiveRecord::Migration[8.0]
  def change
    create_table :processed_refunds do |t|
      t.string  :refund_id,  null: false   # gateway's refund ID
      t.bigint  :payment_id, null: false
      t.string  :source,     null: false   # "razorpay" or "stripe"
      t.timestamps
    end

    add_index :processed_refunds, [:refund_id, :source], unique: true
    add_index :processed_refunds, :payment_id
  end
end
