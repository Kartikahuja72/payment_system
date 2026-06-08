class ReconciliationConsumer < ApplicationConsumer
  include WithOptimisticRetry

  private

  def process(payload)
    payment_id = payload["payment_id"]
    reason     = payload["reason"]
    gateway    = payload["gateway"]

    return if payment_id.to_i.zero?

    # For missing_in_db mismatches detected by the daily job, there is no payment in our DB — the gateway has a record we know nothing about. In that case payment_id is set to 0

    payment = Payment.find(payload["payment_id"])

    Rails.logger.info("[ReconciliationConsumer] Processing payment #{payment.id} | reason=#{reason} | gateway=#{gateway}")

    case reason
    when "pending_verification"
      handle_pending_verification(payment, gateway)
    when "status_mismatch"
      handle_status_mismatch(payment, payload["gateway_value"])
    else
      Rails.logger.warn("[ReconciliationConsumer] Unknown reconciliation reason: #{reason}")
    end
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error("[ReconciliationConsumer] Payment #{payload['payment_id']} not found")
  end

  # Poll the gateway to find the actual status of a stuck payment

  # Bank debited money → Razorpay server crashed → we got no response
  # Payment sits in pending_verification
  # Customer complains: "I was charged but order not confirmed"

  def handle_pending_verification(payment, gateway)
    with_lock_retry do
      status = poll_gateway_status(payment, gateway)
      
      # This is the critical API call. We go directly to Razorpay or Stripe and ask: "What actually happened to this payment?"

      case status
      when "captured", "succeeded"
        payment.reconcile_success!

        mismatch = ReconciliationMismatch.find_by(
          payment_id:    payment.id,
          mismatch_type: "pending_verification"
        )
        mismatch&.resolve!(notes: "Auto-resolved: gateway confirmed capture")

        # Trigger ledger and notification now that we know it succeeded
        KafkaProducer.publish(
          topic:         "ledger.entry.created",
          payload:       {
            payment_id:  payment.id,
            amount:      payment.amount,
            currency:    payment.currency,
            event_type:  "capture",
            trace_id:    payment.trace_id,
            event_id:    SecureRandom.uuid
          },
          partition_key: payment.id
        )

        Rails.logger.info("[ReconciliationConsumer] Payment #{payment.id} reconciled to captured")

      when "failed"
        payment.fail! unless payment.failed?
        Rails.logger.info("[ReconciliationConsumer] Payment #{payment.id} reconciled to failed")

      else
        # Gateway still inconclusive — flag for manual review
        ReconciliationMismatch.find_or_create_by!(
          payment_id:    payment.id,
          mismatch_type: "pending_verification",
          gateway:       gateway
        ) do |m|
          m.our_value     = payment.status
          m.gateway_value = status || "unknown"
          m.status        = "manual_review"
          m.notes         = "Gateway still inconclusive after reconciliation attempt"
        end

        Rails.logger.warn("[ReconciliationConsumer] Payment #{payment.id} still inconclusive at gateway — flagged for manual review")
      end
    end
  end

  # Gateway says success but we marked failed — safe to recover
  def handle_status_mismatch(payment, gateway_status)
    with_lock_retry do
      if gateway_status == "captured" && payment.failed?
        payment.reconcile_success!

        mismatch = ReconciliationMismatch.find_by(
          payment_id:    payment.id,
          mismatch_type: "status_mismatch"
        )
        mismatch&.resolve!(notes: "Auto-resolved: gateway confirmed success")

        Rails.logger.info("[ReconciliationConsumer] Payment #{payment.id} status corrected to captured")
      else
        Rails.logger.warn("[ReconciliationConsumer] Cannot auto-fix status mismatch for payment #{payment.id}: our=#{payment.status} gateway=#{gateway_status}")
      end
    end
  end

  def poll_gateway_status(payment, gateway)
    case gateway
    when "razorpay"
      order = Razorpay::Order.fetch(payment.gateway_payment_id)
      order.status == "paid" ? "captured" : order.status
    when "stripe"
      intent = Stripe::PaymentIntent.retrieve(payment.gateway_payment_id)
      intent.status == "succeeded" ? "captured" : intent.status
    end
  rescue StandardError => e
    Rails.logger.error("[ReconciliationConsumer] Failed to poll gateway for payment #{payment.id}: #{e.message}")
    nil
  end
end
