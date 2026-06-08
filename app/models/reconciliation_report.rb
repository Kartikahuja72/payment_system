class ReconciliationReport < ApplicationRecord
  STATUSES  = %w[pending processed failed].freeze
  GATEWAYS  = %w[razorpay stripe].freeze

  validates :gateway,     inclusion: { in: GATEWAYS }
  validates :status,      inclusion: { in: STATUSES }
  validates :report_date, presence: true
  validates :fetched_at,  presence: true
  validates :report_date, uniqueness: { scope: :gateway }

  scope :pending,   -> { where(status: "pending") }
  scope :processed, -> { where(status: "processed") }
end

# Purpose: Stores the raw settlement data fetched from the gateway for each day. Think of it as archiving the gateway's "statement" for that day.

# status — tracks whether the report has been compared against the DB.
# pending - fetch but not yet compared
# failed - gateway api call failed

