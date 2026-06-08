class CreateInvoices < ActiveRecord::Migration[8.0]
  def change
    create_table :invoices do |t|
      t.bigint   :payment_id,     null: false
      t.string   :invoice_number, null: false
      t.bigint   :amount,         null: false
      t.string   :currency,       null: false, default: "INR"
      t.string   :status,         null: false, default: "issued"
      t.datetime :issued_at,      null: false
      t.timestamps
    end

    add_index :invoices, :payment_id,     unique: true
    add_index :invoices, :invoice_number, unique: true
  end
end
