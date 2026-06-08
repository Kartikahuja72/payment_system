class RetryPaymentProcessingJob < ApplicationJob
  queue_as :retries

  def perform(payload)
    KafkaProducer.publish(
      topic:         "payment.processing",
      payload:       payload,
      partition_key: payload["payment_id"]
    )

    Rails.logger.info("[RetryPaymentProcessingJob] Re-published payment.processing for payment_id=#{payload['payment_id']} retry_count=#{payload['retry_count']}")
  end
end
