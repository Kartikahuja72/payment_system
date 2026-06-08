class CreateLedgerEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :ledger_entries do |t|
      t.references :payment,     null: false, foreign_key: true
      t.string     :entry_type,  null: false   # "authorization", "capture", "refund"
      t.string     :account_type, null: false  # "customer_wallet", "platform_holding", "platform_revenue"
      t.string     :direction,   null: false   # "debit" or "credit"
      t.bigint     :amount,      null: false   # always positive, stored in paise
      t.string     :currency,    null: false
      t.string     :reference_id, null: false  # unique per debit/credit pair — for dedup
      t.string     :trace_id

      # No updated_at — this table is append-only, rows never change after insert
      t.datetime   :created_at,  null: false
    end

    add_index :ledger_entries, :reference_id, unique: true
    add_index :ledger_entries, [:payment_id, :entry_type]
    add_index :ledger_entries, :account_type
    add_index :ledger_entries, :created_at
  end
end
