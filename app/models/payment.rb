class Payment < ApplicationRecord
  has_many :payment_events,  dependent: :destroy
  has_many :ledger_entries,  dependent: :destroy
  has_many :outbox_events, -> { where(aggregate_type: "Payment") },
           foreign_key: :aggregate_id,
           primary_key: :id
  has_one  :saga_transaction, dependent: :destroy
  has_one  :invoice,          dependent: :destroy

  # after_create fires once after the INSERT. state_machine initial state is
  # set by ActiveRecord directly (not via a transition event), so after_transition
  # never fires on create — we record the creation event manually here.
  after_create :record_created_event

  validates :order_id,        presence: true, uniqueness: true
  validates :idempotency_key, presence: true, uniqueness: true
  validates :gateway_payment_id, uniqueness: true, allow_nil: true

  # Rails built-in optimistic locking via lock_version column
  # UPDATE payments SET status=?, lock_version=lock_version+1 WHERE id=? AND lock_version=?
  # Returns 0 rows → raises ActiveRecord::StaleObjectError → caller retries

  state_machine :status, initial: :created do
    # --- valid transitions only ---
    event :submit do
      transition created: :pending #(client submitted, waiting to reach gateway)
    end

    event :start_processing do
      transition pending: :processing #(sent to gateway)
    end

    event :authorize do
      transition processing: :authorized #(gateway reserved the money)
    end

    event :capture do
      transition authorized: :captured #(money moved)
    end

    event :settle do
      transition captured: :settled #(bank confirmed)
    end

    event :fail do
      transition processing: :failed #(gateway rejected, from processing only)
    end

    # Only reconciliation can move failed → success
    #If a payment is marked failed in your DB but the bank shows money moved, reconciliation can recover it
    event :reconcile_success do
      transition failed: :captured #path only exists for the reconciliation engine compares your DB against bank reports
    end

    event :mark_unknown do
      transition [:processing, :pending] => :pending_verification
    end

    event :refund do
      transition captured: :refunded
    end

    after_transition do |payment, transition|
      payment.record_event!(
        event_type: "payment.#{transition.event}",
        from_status: transition.from.to_s,
        to_status: transition.to.to_s
      )
    end
  end

  def record_event!(event_type:, from_status: nil, to_status: nil, payload: {})
    payment_events.create!(
      event_type: event_type,
      from_status: from_status,
      to_status: to_status,
      payload: payload,
      trace_id: trace_id
    )
  end

  def processed_events
    event_ids = outbox_events.pluck(:payload).map { |p| p["event_id"] }.compact
    return ProcessedEvent.none if event_ids.empty?

    ProcessedEvent.where(event_id: event_ids)
  end

  private

  def record_created_event
    record_event!(event_type: "payment.created", to_status: "created")
  end
end


# What problem it solves
# Imagine two workers running at the exact same millisecond — a webhook consumer and a retry worker — both trying to update the same payment:


# Worker A reads payment: { id: 6, status: "processing", lock_version: 3 }
# Worker B reads payment: { id: 6, status: "processing", lock_version: 3 }

# Worker A: payment.authorize!  → tries to write status="authorized"
# Worker B: payment.fail!       → tries to write status="failed"
# Without any protection — whoever writes last wins. Both reads saw processing. Both transitions are valid from processing. One silently overwrites the other. A payment could end up failed even though the gateway said success. Money inconsistency.



# That's it. Rails automatically takes over from there. Every single time you call payment.save!, payment.update!, or any state machine transition — Rails rewrites the SQL behind the scenes:

# What you write:


# payment.authorize!
# What Rails actually executes:


# UPDATE payments
# SET status = 'authorized',
#     lock_version = lock_version + 1,   ← Rails adds this automatically
#     updated_at = '...'
# WHERE id = 6
# AND lock_version = 3                    ← Rails adds this condition too
# The WHERE lock_version = 3 is the key. Only one worker can win.



# The race condition scenario — what actually happens

# Worker A reads:  lock_version = 3
# Worker B reads:  lock_version = 3

# Worker A executes:
#   UPDATE payments SET status='authorized', lock_version=4
#   WHERE id=6 AND lock_version=3
#   → 1 row affected ✓ — lock_version is now 4 in DB

# Worker B executes (milliseconds later):
#   UPDATE payments SET status='failed', lock_version=4
#   WHERE id=6 AND lock_version=3
#   → 0 rows affected ✗ — because lock_version is already 4, not 3
# When Rails sees 0 rows affected, it raises:


# ActiveRecord::StaleObjectError: Attempted to update a stale object: Payment




# How lock_version grew to 4 in your payment
# Each update increments it by 1:


# Payment.create!           → lock_version: 0  (INSERT)
# payment.submit!           → lock_version: 1  (created → pending)
# payment.start_processing! → lock_version: 2  (pending → processing)
# payment.update!(          → lock_version: 3  (gateway_payment_id set)
#   gateway_payment_id: pi_xxx
# )
# payment.authorize!        → lock_version: 4  (processing → authorized)
# payment.capture!          → lock_version: 5  (authorized → captured)
# payment.refund!           → lock_version: 6  (captured → refunded)
# Every DB write — 1 increment. 6 writes after the INSERT = lock_version: 6.