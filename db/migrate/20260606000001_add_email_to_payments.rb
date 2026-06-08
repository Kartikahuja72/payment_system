class AddEmailToPayments < ActiveRecord::Migration[8.0]
  def change
    add_column :payments, :email, :string
    add_index  :payments, :email
  end
end
