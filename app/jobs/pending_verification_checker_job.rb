class PendingVerificationCheckerJob < ApplicationJob
  queue_as :reconciliation

  STUCK_THRESHOLD = 15.minutes

  def perform
    stuck_payments = Payment
                       .where(status: "pending_verification")
                       .where("updated_at < ?", STUCK_THRESHOLD.ago)

    count = stuck_payments.count
    Rails.logger.info("[PendingVerificationCheckerJob] Found #{count} stuck payments")

    stuck_payments.find_each do |payment|
      # Create the mismatch record NOW so ReconciliationConsumer
      # can find and resolve it after polling the gateway.
      ReconciliationMismatch.find_or_create_by!(
        payment_id:    payment.id,
        mismatch_type: "pending_verification",
        gateway:       payment.gateway
      ) do |m|
        m.our_value     = payment.status
        m.gateway_value = "unknown"
        m.status        = "open"
        m.notes         = "Payment stuck in pending_verification for over #{STUCK_THRESHOLD.inspect}"
      end

      KafkaProducer.publish(
        topic:         "reconciliation.required",
        payload:       {
          payment_id:  payment.id,
          gateway:     payment.gateway,
          reason:      "pending_verification",
          trace_id:    payment.trace_id,
          event_id:    SecureRandom.uuid
        },
        partition_key: payment.id
      )

      Rails.logger.info("[PendingVerificationCheckerJob] Queued reconciliation for payment #{payment.id}")
    end
  end
end
