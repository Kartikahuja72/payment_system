class RazorpayReconciliationService
  def initialize(date)
    @date = date
    Razorpay.setup(
      ENV.fetch("RAZORPAY_KEY_ID"), 
      ENV.fetch("RAZORPAY_KEY_SECRET")
    )
  end

  # Fetches all payments from Razorpay for the given date.
  # Returns array of hashes with normalized fields for comparison.
  def fetch_settlements
    from = @date.beginning_of_day.to_i
    to   = @date.end_of_day.to_i

    payments = Razorpay::Payment.all(from: from, to: to, count: 100)

    payments.items.map do |payment|
      {
        gateway_payment_id: payment.order_id,
        gateway_txn_id:     payment.id,
        amount:             payment.amount,
        currency:           payment.currency,
        status:             normalize_razorpay_status(payment.status),
        captured:           payment.captured
      }
    end
  rescue Razorpay::ServerError, Net::TimeoutError => e
    Rails.logger.error("[RazorpayReconciliationService] Failed to fetch settlements for #{@date}: #{e.message}")
    []
  end

  private

  def normalize_razorpay_status(status)
    case status
    when "captured"   then "captured"
    when "authorized" then "authorized"
    when "failed"     then "failed"
    when "refunded"   then "refunded"
    else status
    end
  end
end
