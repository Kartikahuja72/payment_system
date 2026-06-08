class CreateReconciliationReports < ActiveRecord::Migration[8.0]
  def change
    create_table :reconciliation_reports do |t|
      t.string   :gateway,     null: false              # "razorpay" or "stripe"
      t.date     :report_date, null: false              # which day this covers
      t.json     :raw_data,    null: false              # full response from gateway
      t.string   :status,      null: false, default: "pending"  # pending, processed, failed
      t.datetime :fetched_at,  null: false
      t.timestamps
    end

    add_index :reconciliation_reports, [:gateway, :report_date], unique: true
    add_index :reconciliation_reports, :status
  end
end
