class CreateSagaTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :saga_transactions do |t|
      t.string  :saga_id,          null: false
      t.bigint  :payment_id,       null: false
      t.string  :current_step,     null: false
      t.string  :status,           null: false, default: "running"
      t.json    :steps_completed,  null: true
      t.json    :metadata,         null: true
      t.timestamps
    end

    add_index :saga_transactions, :saga_id,    unique: true
    add_index :saga_transactions, :payment_id, unique: true
    add_index :saga_transactions, :status
  end
end
