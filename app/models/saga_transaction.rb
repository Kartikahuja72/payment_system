class SagaTransaction < ApplicationRecord
  belongs_to :payment

  STEPS = %w[
    inventory_reserve
    payment_processing
    payment_authorized
    payment_captured
    invoice_creation
    completed
  ].freeze

  STATUSES = %w[running completed compensating failed].freeze

  after_initialize do
    self.steps_completed ||= []
    self.metadata        ||= {}
  end

  validates :saga_id,      presence: true, uniqueness: true
  validates :current_step, inclusion: { in: STEPS }
  validates :status,       inclusion: { in: STATUSES }

  def advance_to!(step, metadata_update = {})
    completed = (steps_completed || []) | [current_step]
    update!(
      current_step:    step,
      steps_completed: completed,
      metadata:        (metadata || {}).merge(metadata_update)
    )
  end

  def complete!
    advance_to!("completed")
    update!(status: "completed")
  end

  def start_compensation!(reason:)
    update!(status: "compensating", metadata: (metadata || {}).merge(compensation_reason: reason))
  end

  def fail!(reason:)
    update!(status: "failed", metadata: (metadata || {}).merge(failure_reason: reason))
  end

  # Called when something goes wrong. start_compensation! means "we detected a failure and are now 
  # running compensating transactions." fail! means "compensation is done, saga is dead." Both store the 
  # reason in metadata for debugging.
end

# The saga tracker. One row per payment. Tracks the entire multi-step flow from inventory reservation
# to notification sent. The steps_completed JSON array grows as each step finishes — so you can always 
# see exactly how far a saga got if something goes wrong.
