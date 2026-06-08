class OutboxEvent < ApplicationRecord
  STATUSES = %w[pending published failed].freeze

  validates :aggregate_type, :aggregate_id, :event_type, :payload, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :pending,   -> { where(status: "pending") }
  scope :published, -> { where(status: "published") }
end
