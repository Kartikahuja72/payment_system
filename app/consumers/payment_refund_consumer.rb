class PaymentRefundConsumer < ApplicationConsumer
  private

  def process(payload)
    payment = Payment.find(payload["payment_id"])

    # captured → refunded via state machine
    # after_transition automatically writes to payment_events — no manual record_event! needed
    payment.refund!

    Rails.logger.info("[PaymentRefundConsumer] Payment #{payment.id} refunded | refund_id=#{payload['refund_id']} | trace_id=#{payload['trace_id']}")

    KafkaProducer.publish(
      topic:         "notification.send",
      payload:       {
        payment_id: payment.id,
        event_type:    "refund_processed",
        order_id:      payment.order_id,
        refund_amount: payload["amount"] || payment.amount,
        currency:      payment.currency,
        trace_id:   payment.trace_id,
        event_id:   SecureRandom.uuid
      },
      partition_key: payment.id
    )

    KafkaProducer.publish(
      topic:         "ledger.entry.created",
      payload:       {
        payment_id:  payment.id,
        amount:      payload["amount"] || payment.amount,
        currency:    payment.currency,
        event_type:  "refund",
        refund_id:   payload["refund_id"],
        trace_id:    payment.trace_id,
        event_id:    SecureRandom.uuid
      },
      partition_key: payment.id
    )
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error("[PaymentRefundConsumer] Payment #{payload['payment_id']} not found")
    raise
  end
end
