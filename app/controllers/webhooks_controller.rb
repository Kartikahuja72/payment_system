class WebhooksController < ApplicationController
  # Webhooks must read the raw body for signature validation.
  # Rails normally parses the body into params — we need the original bytes.
  before_action :set_raw_body

  def razorpay
    unless RazorpayWebhookValidator.new(@raw_body, razorpay_signature).valid?
      return render json: { error: "Invalid signature" }, status: :bad_request
    end

    payload    = JSON.parse(@raw_body)
    event_type = payload["event"]

    # Use the entity ID that matches the event type.
    # payment.captured  → payment entity id (pay_xxx)
    # refund.created    → refund entity id  (rfnd_xxx)
    # Using the wrong ID causes ApplicationConsumer dedup to skip refund webhooks
    # because the payment ID already exists in processed_events from the capture webhook.
    event_id = if event_type&.start_with?("refund")
                 payload.dig("payload", "refund", "entity", "id")
               else
                 payload.dig("payload", "payment", "entity", "id")
               end || SecureRandom.uuid

    GatewayWebhookLog.create!(
      source:      "razorpay",
      event_id:    event_id,
      event_type:  event_type,
      payload:     payload,
      headers:     webhook_headers,
      signature:   razorpay_signature,
      received_at: Time.current
    )
      
    # This happens before publishing to Kafka
    # Why? If Kafka is temporarily down, the raw payload is still saved in the DB. You can replay it manually later. If you published to Kafka first and then the log create failed, you'd have a Kafka message with no audit record.

    # ACK immediately — never process synchronously
    # Kafka consumer handles the heavy work
    KafkaProducer.publish(
      topic:         "payment.webhook.received", # dedicated topic for all incoming webhooks from all gateways. WebhookReceivedConsumer subscribes to this.
      payload:       {
        source:      "razorpay",
        event_id:    event_id,
        event_type:  event_type,
        payload:     payload,
        received_at: Time.current.iso8601
      },
      partition_key: event_id
    )

    # event_id = "pay_xxx123" ← Razorpay's ID
    # ApplicationConsumer reads payload["event_id"] for processed_events dedup
    # Same webhook arriving twice → same event_id → ApplicationConsumer skips second → correct
    # WebhookReceivedConsumer also checks processed_webhooks as a second dedup layer

    render json: { status: "ok" }, status: :ok
  rescue JSON::ParserError
    render json: { error: "Invalid JSON" }, status: :bad_request
  end

  def stripe
    validator = StripeWebhookValidator.new(@raw_body, stripe_signature)

    unless validator.valid?
      return render json: { error: "Invalid signature" }, status: :bad_request
    end

    event      = validator.event
    event_id   = event["id"]
    event_type = event["type"]

    GatewayWebhookLog.create!(
      source:      "stripe",
      event_id:    event_id,
      event_type:  event_type,
      payload:     event.to_h,
      headers:     webhook_headers,
      signature:   stripe_signature,
      received_at: Time.current
    )

    KafkaProducer.publish(
      topic:         "payment.webhook.received",
      payload:       {
        source:      "stripe",
        event_id:    event_id,
        event_type:  event_type,
        payload:     event.to_h,
        received_at: Time.current.iso8601
      },
      partition_key: event_id
    )

    render json: { status: "ok" }, status: :ok
  end

  private

  def set_raw_body
    request.body.rewind
    @raw_body = request.body.read
  end

  def razorpay_signature
    request.headers["X-Razorpay-Signature"]
  end

  def stripe_signature
    request.headers["Stripe-Signature"]
  end

  def webhook_headers
    request.headers.env
      .select { |k, _| k.start_with?("HTTP_") || k == "CONTENT_TYPE" }
      .transform_keys { |k| k.sub(/^HTTP_/, "").downcase }
  end

  # Rack stores all HTTP headers with HTTP_ prefix and uppercased:


  # HTTP_CONTENT_TYPE         → content_type
  # HTTP_X_RAZORPAY_SIGNATURE → x_razorpay_signature
  # HTTP_USER_AGENT           → user_agent
  # CONTENT_TYPE              → content_type (special case, no HTTP_ prefix)
  # .select { |k, _| k.start_with?("HTTP_") || k == "CONTENT_TYPE" } — filters only actual HTTP headers, skipping internal Rack variables like rack.input, PATH_INFO, SERVER_NAME etc.

  # .transform_keys { |k| k.sub(/^HTTP_/, "").downcase } — strips HTTP_ prefix and lowercases. Result stored in gateway_webhook_logs.headers looks like:


  # {
  #   "content_type": "application/json",
  #   "x_razorpay_signature": "abc123...",
  #   "user_agent": "Razorpay/1.0"
  # }
end


# stripe webhook response body 

# payment_intent.succeeded

# {
#   "id": "evt_3MtweEL2eZvKYlo21234567",
#   "object": "event",
#   "type": "payment_intent.succeeded",
#   "created": 1749123456,
#   "data": {
#     "object": {
#       "id": "pi_3MtweEL2eZvKYlo21234567",
#       "object": "payment_intent",
#       "amount": 50000,
#       "currency": "inr",
#       "status": "succeeded",
#       "payment_method": "pm_1234567",
#       "metadata": {
#         "order_id": "ORD-PHASE3-001",
#         "trace_id": "trace-abc-123"
#       }
#     }
#   }
# }


# payment_intent.payment_failed

# {
#   "id": "evt_3MtweEL2eZvKYlo29876543",
#   "object": "event",
#   "type": "payment_intent.payment_failed",
#   "created": 1749123456,
#   "data": {
#     "object": {
#       "id": "pi_3MtweEL2eZvKYlo29876543",
#       "object": "payment_intent",
#       "amount": 50000,
#       "currency": "inr",
#       "status": "requires_payment_method",
#       "last_payment_error": {
#         "code": "card_declined",
#         "message": "Your card was declined.",
#         "type": "card_error"
#       },
#       "metadata": {
#         "order_id": "ORD-PHASE3-001",
#         "trace_id": "trace-abc-123"
#       }
#     }
#   }
# }


# charge.refunded

# {
#   "id": "evt_3MtweEL2eZvKYlo21111111",
#   "object": "event",
#   "type": "charge.refunded",
#   "created": 1749123456,
#   "data": {
#     "object": {
#       "id": "ch_3MtweEL2eZvKYlo21111111",
#       "object": "charge",
#       "amount": 50000,
#       "amount_refunded": 50000,
#       "currency": "inr",
#       "payment_intent": "pi_3MtweEL2eZvKYlo21234567",
#       "refunds": {
#         "data": [
#           {
#             "id": "re_3MtweEL2eZvKYlo21111111",
#             "amount": 50000,
#             "currency": "inr",
#             "status": "succeeded"
#           }
#         ]
#       }
#     }
#   }
# }


# rozorpay webhook response body

# payment.captured

# {
#   "entity": "event",
#   "account_id": "acc_BFQ7uQEaa6eod",
#   "event": "payment.captured",
#   "contains": ["payment"],
#   "payload": {
#     "payment": {
#       "entity": {
#         "id": "pay_SwlddaYVPuUlIp",
#         "entity": "payment",
#         "amount": 50000,
#         "currency": "INR",
#         "status": "captured",
#         "order_id": "order_SwlddaYVPuUlIp",
#         "method": "card",
#         "captured": true,
#         "description": "Payment for ORD-PHASE3-001",
#         "email": "customer@example.com",
#         "contact": "+919999999999",
#         "created_at": 1749123456
#       }
#     }
#   },
#   "created_at": 1749123456
# }


# payment.failed

# {
#   "entity": "event",
#   "account_id": "acc_BFQ7uQEaa6eod",
#   "event": "payment.failed",
#   "contains": ["payment"],
#   "payload": {
#     "payment": {
#       "entity": {
#         "id": "pay_FailedXYZ123",
#         "entity": "payment",
#         "amount": 50000,
#         "currency": "INR",
#         "status": "failed",
#         "order_id": "order_SwlddaYVPuUlIp",
#         "method": "card",
#         "captured": false,
#         "error_code": "BAD_REQUEST_ERROR",
#         "error_description": "Your card has insufficient funds.",
#         "error_source": "customer",
#         "error_reason": "insufficient_funds",
#         "created_at": 1749123456
#       }
#     }
#   },
#   "created_at": 1749123456
# }


# refund.created

# {
#   "entity": "event",
#   "account_id": "acc_BFQ7uQEaa6eod",
#   "event": "refund.created",
#   "contains": ["refund", "payment"],
#   "payload": {
#     "refund": {
#       "entity": {
#         "id": "rfnd_FgRAHdNOM4ZVbO",
#         "entity": "refund",
#         "amount": 50000,
#         "currency": "INR",
#         "payment_id": "pay_SwlddaYVPuUlIp",
#         "order_id": "order_SwlddaYVPuUlIp",
#         "status": "processed",
#         "created_at": 1749123456
#       }
#     },
#     "payment": {
#       "entity": {
#         "id": "pay_SwlddaYVPuUlIp",
#         "amount": 50000,
#         "currency": "INR",
#         "status": "refunded"
#       }
#     }
#   },
#   "created_at": 1749123456
# }


