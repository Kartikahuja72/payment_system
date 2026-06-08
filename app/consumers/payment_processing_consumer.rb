class PaymentProcessingConsumer < ApplicationConsumer
  include WithOptimisticRetry

  private

  def process(payload)
    payment_id  = payload["payment_id"]
    retry_count = payload.fetch("retry_count", 0).to_i

    PaymentLock.with_lock(payment_id) do
      with_lock_retry do
        payment = Payment.find(payment_id)

        payment.start_processing!

        gateway  = select_gateway(payment.gateway)
        response = gateway.authorize(payment)

        if response.success?
          handle_success(payment, response)
        else
          handle_failure(payment, response, payload, retry_count)
        end
      end
    end
  rescue PaymentLock::PaymentLockError => e
    Rails.logger.warn("[PaymentProcessingConsumer] #{e.message} — skipping")
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error("[PaymentProcessingConsumer] Payment #{payload['payment_id']} not found")
    raise
  rescue StateMachines::InvalidTransition => e
    Rails.logger.warn("[PaymentProcessingConsumer] Skipping — invalid transition: #{e.message}")
  end

  def handle_success(payment, response)
    payment.update!(gateway_payment_id: response.gateway_payment_id)
    payment.authorize!

    KafkaProducer.publish(
      topic:         "payment.authorized",
      payload:       {
        payment_id:         payment.id,
        gateway_payment_id: payment.gateway_payment_id,
        gateway:            payment.gateway,
        trace_id:           payment.trace_id,
        event_id:           SecureRandom.uuid
      },
      partition_key: payment.id
    )

    Rails.logger.info("[PaymentProcessingConsumer] Payment #{payment.id} authorized | gateway_payment_id=#{payment.gateway_payment_id}")
  end

  def handle_failure(payment, response, payload, retry_count)
    Rails.logger.warn("[PaymentProcessingConsumer] Payment #{payment.id} failed | error=#{response.error_code} | message=#{response.error_message}")

    if GatewayErrorClassifierService.non_retryable?(response.error_code)
      payment.fail!
      publish_failed(payment, response)

    elsif GatewayRetryEngineService.max_retries_exceeded?(retry_count)
      payment.mark_unknown!
      publish_to_dlq(payment, response, retry_count)

    else
      delay      = GatewayRetryEngineService.next_delay(retry_count)
      new_payload = payload.merge(
        "retry_count" => retry_count + 1,
        "event_id"    => SecureRandom.uuid
      )

      # Schedule re-publish via Resque so the actual delay is honoured.
      # We cannot sleep inside a Kafka consumer — it blocks the thread and
      # prevents any other messages from being consumed during that time.
      RetryPaymentProcessingJob
        .set(wait: delay.seconds)
        .perform_later(new_payload)

      Rails.logger.info("[PaymentProcessingConsumer] Payment #{payment.id} scheduled retry in #{delay}s (attempt #{retry_count + 1})")
    end
  end

  def publish_failed(payment, response)
    KafkaProducer.publish(
      topic:         "payment.failed",
      payload:       {
        payment_id:    payment.id,
        error_code:    response.error_code,
        error_message: response.error_message,
        trace_id:      payment.trace_id,
        event_id:      SecureRandom.uuid
      },
      partition_key: payment.id
    )
  end

  def publish_to_dlq(payment, response, retry_count)
    Rails.logger.error("[PaymentProcessingConsumer] Payment #{payment.id} moved to DLQ after #{retry_count} retries")

    KafkaProducer.publish(
      topic:         "deadletter.payment",
      payload:       {
        payment_id:    payment.id,
        error_code:    response.error_code,
        error_message: response.error_message,
        retry_count:   retry_count,
        trace_id:      payment.trace_id,
        event_id:      SecureRandom.uuid
      },
      partition_key: payment.id
    )
  end

  def select_gateway(gateway_name)
    case gateway_name
    when "razorpay" then RazorpayGateway.new
    when "stripe"   then StripeGateway.new
    else
      raise "Unknown gateway: #{gateway_name}"
    end
  end
end
