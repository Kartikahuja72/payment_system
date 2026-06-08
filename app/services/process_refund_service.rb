class ProcessRefundService
  Result = Struct.new(:success?, :payment, :error, keyword_init: true)

  def initialize(payment:, idempotency_key:, trace_id:)
    @payment         = payment
    @idempotency_key = idempotency_key
    @trace_id        = trace_id
  end

  def call
    # SELECT FOR UPDATE locks the payment row at read time.
    # Two concurrent refund requests both pass captured? check before either writes.
    # The lock forces the second request to wait until the first completes —
    # by then status='refunded' and captured? returns false → safe rejection.
    @payment = Payment.lock("FOR UPDATE").find(@payment.id)

    # FOR UPDATE tells MySQL: lock this row for the duration of the current transaction. No other connection can read this row with FOR UPDATE until the first transaction commits or rolls back.

    # The scenario this prevents:
    # Two refund requests arrive simultaneously (different idempotency keys)

    # Without FOR UPDATE:
    #   Request A: payment.captured? → true  (reads unlocked)
    #   Request B: payment.captured? → true  (reads unlocked, both pass)
    #   Both call gateway.refund() → customer refunded TWICE

    # With FOR UPDATE:
    #   Request A: SELECT ... FOR UPDATE → row LOCKED
    #   Request B: SELECT ... FOR UPDATE → WAITS (blocked at DB level)
    #   Request A: refund() → payment.refund! → status='refunded' → COMMIT → unlock
    #   Request B: row unlocked → SELECT → status='refunded' → captured? → false → return error

    unless @payment.captured?
      return Result.new(success?: false, payment: @payment, error: "Payment must be captured before refunding")
    end

    gateway  = select_gateway(@payment.gateway)
    response = gateway.refund(@payment)

    unless response.success?
      return Result.new(success?: false, payment: @payment, error: response.error_message)
    end

    # Do NOT publish to payment.refund here.
    # The webhook (refund.created from Razorpay / charge.refunded from Stripe)
    # is the single canonical event that triggers ledger + notification.
    # Publishing here AND from the webhook handler would create two ledger entries.
    # The webhook arrives shortly after — let it be the source of truth.

    Rails.logger.info("[ProcessRefundService] Refund initiated at gateway for payment #{@payment.id} | gateway=#{@payment.gateway}")

    Result.new(success?: true, payment: @payment, error: nil)
  rescue StandardError => e
    Rails.logger.error("[ProcessRefundService] Refund failed for payment #{@payment.id}: #{e.message}")
    Result.new(success?: false, payment: @payment, error: e.message)
  end

  private

  def select_gateway(gateway_name)
    case gateway_name
    when "razorpay" then RazorpayGateway.new
    when "stripe"   then StripeGateway.new
    else raise "Unknown gateway: #{gateway_name}"
    end
  end
end
