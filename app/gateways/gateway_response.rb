GatewayResponse = Struct.new(
  :success?,
  :gateway_payment_id,
  :error_code,
  :error_message,
  :raw_response,
  keyword_init: true
)


#gateway_payment_id: 	The ID the gateway assigned (order_id from Razorpay, pi_xxx from Stripe)
#error_code:  	Standard symbol: :timeout, :invalid_card, :insufficient_funds
#error_message:  	Human-readable message from the gateway