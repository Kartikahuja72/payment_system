class StripeGateway
  include PaymentGateway

  def initialize
    Stripe.api_key = ENV.fetch("STRIPE_SECRET_KEY")
  end

  def authorize(payment)
    intent = Stripe::PaymentIntent.create(
      amount:               payment.amount,         # already in paise/cents
      currency:             payment.currency.downcase,
      payment_method_types: ["card"],
      metadata:             {
        order_id:  payment.order_id,
        trace_id:  payment.trace_id
      }
    )

    GatewayResponse.new(
      success?:           true,
      gateway_payment_id: intent.id,
      raw_response:       intent.to_json
    )
  rescue Stripe::CardError => e
    GatewayResponse.new(
      success?:      false,
      error_code:    classify_stripe_error(e),
      error_message: e.message,
      raw_response:  e.json_body.to_s
    )
  rescue Stripe::RateLimitError, Stripe::APIConnectionError => e
    GatewayResponse.new(
      success?:      false,
      error_code:    :too_many_requests,
      error_message: e.message,
      raw_response:  e.class.to_s
    )
  rescue Stripe::APIError => e
    GatewayResponse.new(
      success?:      false,
      error_code:    :service_unavailable,
      error_message: e.message,
      raw_response:  e.class.to_s
    )
  end

  def capture(payment)
    Stripe::PaymentIntent.capture(payment.gateway_payment_id)
    GatewayResponse.new(success?: true, gateway_payment_id: payment.gateway_payment_id)
  rescue Stripe::StripeError => e
    GatewayResponse.new(success?: false, error_code: :bad_gateway, error_message: e.message)
  end

  def refund(payment)
    Stripe::Refund.create(payment_intent: payment.gateway_payment_id)
    GatewayResponse.new(success?: true, gateway_payment_id: payment.gateway_payment_id)
  rescue Stripe::StripeError => e
    GatewayResponse.new(success?: false, error_code: :bad_gateway, error_message: e.message)
  end

  def void(payment)
    Stripe::PaymentIntent.cancel(payment.gateway_payment_id)
    GatewayResponse.new(success?: true, gateway_payment_id: payment.gateway_payment_id)
  rescue Stripe::StripeError => e
    GatewayResponse.new(success?: false, error_code: :bad_gateway, error_message: e.message)
  end

  private

  def classify_stripe_error(exception)
    code = exception.code&.to_sym
    case code
    when :insufficient_funds     then :insufficient_funds
    when :card_declined          then :do_not_honor
    when :expired_card           then :card_expired
    when :incorrect_cvc          then :invalid_cvv
    when :invalid_card_number    then :invalid_card
    when :authentication_required then :auth_failure
    else :bad_gateway
    end
  end
end
