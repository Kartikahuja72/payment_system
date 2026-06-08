class PaymentFailedConsumer < ApplicationConsumer
  private

  def process(payload)
    payment = Payment.find(payload["payment_id"])

    Rails.logger.warn("[PaymentFailedConsumer] Payment #{payment.id} failed | error_code=#{payload['error_code']} | error=#{payload['error_message']} | trace_id=#{payload['trace_id']}")

    # ── Compensating transaction — release reserved inventory ─────────────────
    # Step 1 of saga was inventory_reserve. Since payment failed we must undo it.
    saga = SagaTransaction.find_by(payment_id: payment.id)
    if saga&.status == "running"
      saga.start_compensation!(reason: "payment_failed: #{payload['error_code']}")

      KafkaProducer.publish(
        topic:         "inventory.release",
        payload:       {
          saga_id:    saga.saga_id,
          payment_id: payment.id,
          order_id:   payment.order_id,
          reason:     "payment_failed",
          trace_id:   payment.trace_id,
          event_id:   SecureRandom.uuid
        },
        partition_key: payment.id
      )

      saga.fail!(reason: "payment_failed")
      Rails.logger.info("[PaymentFailedConsumer] Compensating transaction published inventory.release | payment=#{payment.id}")
    end

    # ── Notify the customer ───────────────────────────────────────────────────
    KafkaProducer.publish(
      topic:         "notification.send",
      payload:       {
        payment_id:    payment.id,
        event_type:    "payment_failed",
        order_id:      payment.order_id,
        amount:        payment.amount,
        currency:      payment.currency,
        email:         payment.email,
        error_code:    payload["error_code"],
        error_message: payload["error_message"],
        trace_id:      payment.trace_id,
        event_id:      SecureRandom.uuid
      },
      partition_key: payment.id
    )
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error("[PaymentFailedConsumer] Payment #{payload['payment_id']} not found")
    raise
  end
end
