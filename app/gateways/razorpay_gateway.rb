class RazorpayGateway
  include PaymentGateway

  def initialize
    Razorpay.setup(
      ENV.fetch("RAZORPAY_KEY_ID"),
      ENV.fetch("RAZORPAY_KEY_SECRET")
    )
  end

  def authorize(payment)
    order = Razorpay::Order.create(
      amount:   payment.amount,       # already in paise
      currency: payment.currency,
      receipt:  payment.order_id,
      notes:    { trace_id: payment.trace_id }
    )

    GatewayResponse.new(
      success?:           true,
      gateway_payment_id: order.id,
      raw_response:       order.to_json
    )
  rescue Razorpay::BadRequestError => e
    GatewayResponse.new(
      success?:      false,
      error_code:    classify_razorpay_error(e),
      error_message: e.message,
      raw_response:  e.response.to_s
    )
  rescue Razorpay::ServerError, Net::TimeoutError, Errno::ECONNRESET => e
    GatewayResponse.new(
      success?:      false,
      error_code:    :timeout,
      error_message: e.message,
      raw_response:  e.class.to_s
    )
    # All three get mapped to :timeout error code. The GatewayRetryEngine will retry these. We don't know if Razorpay processed the request before crashing — this is the "gateway timeout after debit" scenario
    # The payment gets moved to pending_verification if max retries exceeded.
  end

  def capture(payment)
    Razorpay::Payment.fetch(payment.gateway_payment_id).capture(
      amount: payment.amount
    )
    GatewayResponse.new(success?: true, gateway_payment_id: payment.gateway_payment_id)
  rescue Razorpay::BadRequestError => e
    GatewayResponse.new(success?: false, error_code: classify_razorpay_error(e), error_message: e.message)
  end

  def refund(payment)
    Razorpay::Payment.fetch(payment.gateway_payment_id).refund(amount: payment.amount)
    GatewayResponse.new(success?: true, gateway_payment_id: payment.gateway_payment_id)
  rescue Razorpay::BadRequestError => e
    GatewayResponse.new(success?: false, error_code: classify_razorpay_error(e), error_message: e.message)
  end

  def void(payment)
    # Razorpay orders cannot be voided directly — mark cancelled internally
    GatewayResponse.new(success?: true, gateway_payment_id: payment.gateway_payment_id)
  end

  private

  def classify_razorpay_error(exception)
    msg = exception.message.downcase
    return :insufficient_funds  if msg.include?("insufficient")
    return :invalid_card        if msg.include?("invalid card") || msg.include?("card number")
    return :card_expired        if msg.include?("expired")
    return :invalid_cvv         if msg.include?("cvv")
    return :auth_failure        if msg.include?("authentication") || msg.include?("authorization")
    return :do_not_honor        if msg.include?("do not honor")
    :bad_gateway
  end
end
