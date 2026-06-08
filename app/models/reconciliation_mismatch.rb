class ReconciliationMismatch < ApplicationRecord
  belongs_to :payment

  MISMATCH_TYPES = %w[
    amount_mismatch
    status_mismatch
    missing_in_gateway
    missing_in_db
    refund_mismatch
    pending_verification
  ].freeze

  STATUSES = %w[open resolved manual_review].freeze

  validates :mismatch_type, inclusion: { in: MISMATCH_TYPES }
  validates :status,        inclusion: { in: STATUSES }
  validates :our_value,     presence: true
  validates :gateway_value, presence: true

  scope :open,          -> { where(status: "open") }
  scope :manual_review, -> { where(status: "manual_review") }

  def resolve!(notes: nil)
    update!(status: "resolved", resolved_at: Time.current, notes: notes)
  end

  def flag_for_manual_review!(notes: nil)
    update!(status: "manual_review", notes: notes)
  end
end

# Every detected discrepancy gets a row here. This is your investigation dashboard

# amount_mismatch — DB says ₹500, gateway settled ₹499 (fee deducted)
# status_mismatch — DB says failed, gateway says captured
# missing_in_gateway — DB has payment, gateway has no record
# missing_in_db — Gateway has captured payment, DB has no record (critical — money moved without your knowledge)
# refund_mismatch — Gateway shows refund, DB has no record

# open — detected, not yet resolved
# resolved — auto-fixed by reconciliation engine
# manual_review — cannot be auto-fixed, needs human investigation