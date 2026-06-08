class LedgerEntryConsumer < ApplicationConsumer
  private

  def process(payload)
    payment      = Payment.find(payload["payment_id"])
    event_type   = payload["event_type"]
    amount       = payload["amount"]&.to_i || payment.amount
    currency     = payload["currency"]     || payment.currency
    trace_id     = payload["trace_id"]     || payment.trace_id
    reference_id = payload["event_id"]     # unique per Kafka message — dedup key for ledger

    service = LedgerEntryService.new(
      payment:      payment,
      amount:       amount,
      currency:     currency,
      trace_id:     trace_id,
      reference_id: reference_id
    )

    case event_type
    when "authorization"
      service.record_authorization
    when "capture"
      service.record_capture
    when "refund"
      service.record_refund
    else
      Rails.logger.warn("[LedgerEntryConsumer] Unknown event_type: #{event_type} for payment #{payment.id}")
      return
    end

    # Verify the ledger is still balanced after this write
    unless LedgerEntry.balanced_for?(payment.id)
      Rails.logger.error("[LedgerEntryConsumer] LEDGER IMBALANCE DETECTED for payment #{payment.id}")
    end
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error("[LedgerEntryConsumer] Payment #{payload['payment_id']} not found")
    raise
  rescue ActiveRecord::RecordNotUnique
    # reference_id already exists — this is a duplicate Kafka message, safe to skip
    Rails.logger.warn("[LedgerEntryConsumer] Duplicate ledger entry skipped for reference_id=#{payload['event_id']}")
  end
end
