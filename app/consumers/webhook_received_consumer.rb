class WebhookReceivedConsumer < ApplicationConsumer
  include WithOptimisticRetry

  private

  def process(payload)
    source     = payload["source"]
    event_id   = payload["event_id"]
    event_type = payload["event_type"]
    data       = payload["payload"]

    return if already_processed_webhook?(event_id, source)

    payment_id = extract_payment_id(event_type, data, source)

    if payment_id
      PaymentLock.with_lock(payment_id) do
        with_lock_retry do
          case source
          when "razorpay" then handle_razorpay(event_type, data)
          when "stripe"   then handle_stripe(event_type, data)
          else
            Rails.logger.warn("[WebhookReceivedConsumer] Unknown source: #{source}")
          end
        end
      end
    else
      case source
      when "razorpay" then handle_razorpay(event_type, data)
      when "stripe"   then handle_stripe(event_type, data)
      end
    end

    mark_webhook_processed!(event_id, source)
    Rails.logger.info("[WebhookReceivedConsumer] Processed #{source} #{event_type} event_id=#{event_id}")
  rescue PaymentLock::PaymentLockError => e
    Rails.logger.warn("[WebhookReceivedConsumer] #{e.message} — skipping")
  end

  # ─── Razorpay handlers ───────────────────────────────────────────────────

  def handle_razorpay(event_type, data)
    case event_type
    when "payment.captured"
      handle_payment_captured_razorpay(data)
    when "payment.failed"
      handle_payment_failed_razorpay(data)
    when "refund.created"
      handle_refund_razorpay(data)
    else
      Rails.logger.info("[WebhookReceivedConsumer] Unhandled Razorpay event: #{event_type}")
    end
  end

  def handle_payment_captured_razorpay(data)
    entity   = data.dig("payload", "payment", "entity") || data
    order_id = entity["order_id"]
    payment  = Payment.find_by!(gateway_payment_id: order_id)

    # authorized → captured — money has actually moved now
    payment.capture!

    publish_capture_events(payment)
  end

  def handle_payment_failed_razorpay(data)
    entity   = data.dig("payload", "payment", "entity") || data
    order_id = entity["order_id"]
    payment  = Payment.find_by!(gateway_payment_id: order_id)

    payment.fail! unless payment.failed?

    KafkaProducer.publish(
      topic:         "payment.failed",
      payload:       {
        payment_id:    payment.id,
        error_code:    entity.dig("error_code") || "gateway_error",
        error_message: entity.dig("error_description") || "Payment failed",
        trace_id:      payment.trace_id,
        event_id:      SecureRandom.uuid
      },
      partition_key: payment.id
    )
  end

  def handle_refund_razorpay(data)
    entity     = data.dig("payload", "refund", "entity") || data
    refund_id = entity["id"]
    order_id  = entity["order_id"]   # We store Razorpay ORDER ID as gateway_payment_id,
                                     # not the payment ID (pay_xxx). Must look up by order_id.
    payment   = Payment.find_by!(gateway_payment_id: order_id)

    return if ProcessedRefund.exists?(refund_id: refund_id, source: "razorpay")

    ProcessedRefund.create!(refund_id: refund_id, payment_id: payment.id, source: "razorpay")

    KafkaProducer.publish(
      topic:         "payment.refund",
      payload:       {
        payment_id: payment.id,
        refund_id:  refund_id,
        amount:     entity["amount"],
        trace_id:   payment.trace_id,
        event_id:   SecureRandom.uuid
      },
      partition_key: payment.id
    )
  end

  # ─── Stripe handlers ─────────────────────────────────────────────────────

  def handle_stripe(event_type, data)
    case event_type
    when "payment_intent.succeeded"
      handle_payment_captured_stripe(data)
    when "payment_intent.payment_failed"
      handle_payment_failed_stripe(data)
    when "charge.refunded"
      handle_refund_stripe(data)
    else
      Rails.logger.info("[WebhookReceivedConsumer] Unhandled Stripe event: #{event_type}")
    end
  end

  def handle_payment_captured_stripe(data)
    intent_id = data.dig("data", "object", "id") || data["id"]
    payment   = Payment.find_by!(gateway_payment_id: intent_id)

    # authorized → captured — money has actually moved now
    payment.capture!

    publish_capture_events(payment)
  end

  def handle_payment_failed_stripe(data)
    intent    = data.dig("data", "object") || data
    intent_id = intent["id"]
    payment   = Payment.find_by!(gateway_payment_id: intent_id)

    payment.fail! unless payment.failed?

    KafkaProducer.publish(
      topic:         "payment.failed",
      payload:       {
        payment_id:    payment.id,
        error_code:    intent.dig("last_payment_error", "code") || "gateway_error",
        error_message: intent.dig("last_payment_error", "message") || "Payment failed",
        trace_id:      payment.trace_id,
        event_id:      SecureRandom.uuid
      },
      partition_key: payment.id
    )
  end

  def handle_refund_stripe(data)
    charge    = data.dig("data", "object") || data
    refund    = charge.dig("refunds", "data", 0) || {}
    refund_id = refund["id"] || charge["id"]
    intent_id = charge["payment_intent"]
    payment   = Payment.find_by!(gateway_payment_id: intent_id)

    return if ProcessedRefund.exists?(refund_id: refund_id, source: "stripe")

    ProcessedRefund.create!(refund_id: refund_id, payment_id: payment.id, source: "stripe")

    KafkaProducer.publish(
      topic:         "payment.refund",
      payload:       {
        payment_id: payment.id,
        refund_id:  refund_id,
        amount:     refund["amount"] || charge["amount_refunded"],
        trace_id:   payment.trace_id,
        event_id:   SecureRandom.uuid
      },
      partition_key: payment.id
    )
  end

  # ─── Shared helpers ──────────────────────────────────────────────────────

  def publish_capture_events(payment)
    # Advance saga to payment_captured step
    saga = SagaTransaction.find_by(payment_id: payment.id)
    saga&.advance_to!("payment_captured", captured_at: Time.current.iso8601)

    # Tell the ledger to record the actual money movement
    KafkaProducer.publish(
      topic:         "ledger.entry.created",
      payload:       {
        payment_id:         payment.id,
        amount:             payment.amount,
        currency:           payment.currency,
        event_type:         "capture",
        gateway_payment_id: payment.gateway_payment_id,
        trace_id:           payment.trace_id,
        event_id:           SecureRandom.uuid
      },
      partition_key: payment.id
    )

    # Notify the user immediately — payment confirmed
    KafkaProducer.publish(
      topic:         "notification.send",
      payload:       {
        payment_id:  payment.id,
        event_type:  "payment_captured",
        order_id:    payment.order_id,
        amount:      payment.amount,
        currency:    payment.currency,
        email:       payment.email,
        trace_id:    payment.trace_id,
        event_id:    SecureRandom.uuid
      },
      partition_key: payment.id
    )

    # Trigger invoice generation — Step 4 of the saga
    KafkaProducer.publish(
      topic:         "invoice.create",
      payload:       {
        payment_id: payment.id,
        order_id:   payment.order_id,
        amount:     payment.amount,
        currency:   payment.currency,
        trace_id:   payment.trace_id,
        event_id:   SecureRandom.uuid
      },
      partition_key: payment.id
    )

    Rails.logger.info("[WebhookReceivedConsumer] Payment #{payment.id} captured | trace_id=#{payment.trace_id}")
  end

  # ─── Lock helpers ────────────────────────────────────────────────────────

  def extract_payment_id(event_type, data, source)
    if source == "razorpay"
      order_id = data.dig("payload", "payment", "entity", "order_id") ||
                 data.dig("payload", "refund",  "entity", "order_id")
      Payment.find_by(gateway_payment_id: order_id)&.id
    elsif source == "stripe"
      intent_id = data.dig("data", "object", "id") ||
                  data.dig("data", "object", "payment_intent")
      Payment.find_by(gateway_payment_id: intent_id)&.id
    end
  rescue StandardError
    nil
  end

  # ─── Deduplication helpers ────────────────────────────────────────────────

  def already_processed_webhook?(event_id, source)
    ProcessedWebhook.exists?(event_id: event_id, source: source)
  end

  def mark_webhook_processed!(event_id, source)
    ProcessedWebhook.create!(event_id: event_id, source: source)
  rescue ActiveRecord::RecordNotUnique
    # Another worker already processed this webhook — safe to ignore
  end
end
