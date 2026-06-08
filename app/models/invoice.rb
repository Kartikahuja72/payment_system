class Invoice < ApplicationRecord
  belongs_to :payment

  STATUSES = %w[issued cancelled].freeze
  
  # STATUSES = %w[issued cancelled] — an invoice can only be cancelled, never deleted, for accounting 

  validates :invoice_number, presence: true, uniqueness: true
  validates :amount,         presence: true, numericality: { greater_than: 0 }
  validates :status,         inclusion: { in: STATUSES }
  validates :issued_at,      presence: true
  validates :payment_id,     uniqueness: true
end
