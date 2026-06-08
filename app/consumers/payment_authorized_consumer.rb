class PaymentAuthorizedConsumer < ApplicationConsumer
  private

  def process(payload)
    payment = Payment.find(payload["payment_id"])

    # Advance saga — money is reserved at the gateway, waiting for capture
    saga = SagaTransaction.find_by(payment_id: payment.id)
    saga&.advance_to!("payment_authorized", authorized_at: Time.current.iso8601)

    # Record authorization in ledger — debit customer_wallet, credit platform_holding
    KafkaProducer.publish(
      topic:         "ledger.entry.created",
      payload:       {
        payment_id:         payment.id,
        amount:             payment.amount,
        currency:           payment.currency,
        event_type:         "authorization",
        gateway_payment_id: payment.gateway_payment_id,
        trace_id:           payment.trace_id,
        event_id:           SecureRandom.uuid
      },
      partition_key: payment.id
    )

    Rails.logger.info("[PaymentAuthorizedConsumer] Payment #{payment.id} authorized | gateway_payment_id=#{payment.gateway_payment_id} | trace_id=#{payload['trace_id']}")
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error("[PaymentAuthorizedConsumer] Payment #{payload['payment_id']} not found")
    raise
  end
end
