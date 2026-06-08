class PaymentCreatedConsumer < ApplicationConsumer
  private

  def process(payload)
    payment = Payment.find(payload["payment_id"])

    payment.submit!

    # Publish payment.processing so GatewayProcessorConsumer picks it up.
    # We publish directly from the consumer (no outbox needed) because we are
    # already in the async Kafka world — atomicity with the DB is not required here.
    KafkaProducer.publish(
      topic:         "payment.processing",
      payload:       {
        payment_id:  payment.id,
        order_id:    payment.order_id,
        amount:      payment.amount,
        currency:    payment.currency,
        gateway:     payment.gateway,
        trace_id:    payment.trace_id,
        event_id:    SecureRandom.uuid,
        retry_count: 0
      },
      partition_key: payment.id
    )

    Rails.logger.info("[PaymentCreatedConsumer] Payment #{payment.id} → pending, payment.processing published | trace_id=#{payload['trace_id']}")
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error("[PaymentCreatedConsumer] Payment #{payload['payment_id']} not found")
    raise
  rescue StateMachines::InvalidTransition => e
    Rails.logger.warn("[PaymentCreatedConsumer] Invalid transition for payment #{payload['payment_id']}: #{e.message}")
  end
end
