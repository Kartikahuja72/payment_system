class StripeReconciliationService
  def initialize(date)
    @date = date
    Stripe.api_key = ENV.fetch("STRIPE_SECRET_KEY")
  end

  # Fetches all payment intents from Stripe for the given date.
  # Returns array of hashes with normalized fields for comparison.
  def fetch_settlements
    from = @date.beginning_of_day.to_i
    to   = @date.end_of_day.to_i

    intents = Stripe::PaymentIntent.list(
      created: { gte: from, lte: to },
      limit:   100
    )

    intents.data.map do |intent|
      {
        gateway_payment_id: intent.id,
        gateway_txn_id:     intent.id,
        amount:             intent.amount,
        currency:           intent.currency.upcase,
        status:             normalize_stripe_status(intent.status),
        captured:           intent.status == "succeeded"
      }
    end
  rescue Stripe::APIConnectionError, Stripe::APIError => e
    Rails.logger.error("[StripeReconciliationService] Failed to fetch settlements for #{@date}: #{e.message}")
    []
  end

  private

  def normalize_stripe_status(status)
    case status
    when "succeeded"                then "captured"
    when "requires_capture"         then "authorized"
    when "requires_payment_method"  then "failed"
    when "canceled"                 then "failed"
    else status
    end
  end
end
