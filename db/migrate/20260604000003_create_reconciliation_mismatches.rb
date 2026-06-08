class CreateReconciliationMismatches < ActiveRecord::Migration[8.0]
  def change
    create_table :reconciliation_mismatches do |t|
      t.references :payment,       null: false, foreign_key: true
      t.string     :mismatch_type, null: false
      # amount_mismatch    — gateway settled different amount than DB
      # status_mismatch    — DB status differs from gateway status
      # missing_in_gateway — payment exists in DB but not at gateway
      # missing_in_db      — gateway has payment with no DB record
      # refund_mismatch    — refund at gateway not recorded in DB

      t.string     :our_value,     null: false  # what our DB says
      t.string     :gateway_value, null: false  # what the gateway says
      t.string     :gateway,       null: false  # "razorpay" or "stripe"
      t.string     :status,        null: false, default: "open"
      # open          — detected, not yet resolved
      # resolved      — auto-fixed by reconciliation engine
      # manual_review — needs human investigation

      t.text       :notes
      t.datetime   :resolved_at
      t.timestamps
    end

    add_index :reconciliation_mismatches, [:payment_id, :mismatch_type]
    add_index :reconciliation_mismatches, :status
    add_index :reconciliation_mismatches, :mismatch_type
  end
end
