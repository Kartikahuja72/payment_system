class LedgerEntry < ApplicationRecord
  belongs_to :payment

  DIRECTIONS    = %w[debit credit].freeze
  ENTRY_TYPES   = %w[authorization capture refund].freeze
  ACCOUNT_TYPES = %w[customer_wallet platform_holding platform_revenue].freeze

  validates :direction,    inclusion: { in: DIRECTIONS }
  validates :entry_type,   inclusion: { in: ENTRY_TYPES }
  validates :account_type, inclusion: { in: ACCOUNT_TYPES }
  validates :amount,       numericality: { greater_than: 0 }
  validates :currency,     presence: true
  validates :reference_id, presence: true, uniqueness: true

  # Immutable — ledger entries are permanent financial records
  before_update  { raise "LedgerEntry records are immutable" }
  before_destroy { raise "LedgerEntry records are immutable" }

  # ── Balance queries ──────────────────────────────────────────────────────────

  def self.balanced_for?(payment_id)
    entries  = where(payment_id: payment_id)
    debits   = entries.where(direction: "debit").sum(:amount)
    credits  = entries.where(direction: "credit").sum(:amount)
    debits == credits
  end

  def self.balance_for(payment_id)
    entries = where(payment_id: payment_id)
    {
      total_debited:  entries.where(direction: "debit").sum(:amount),
      total_credited: entries.where(direction: "credit").sum(:amount),
      balanced:       balanced_for?(payment_id)
    }
  end
end
