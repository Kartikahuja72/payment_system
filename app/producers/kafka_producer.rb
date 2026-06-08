module KafkaProducer
  # All publish calls go through here — no code touches Karafka's producer directly.
  # partition_key is always payment_id.to_s so all events for the same payment
  # land in the same partition and arrive in order.

  def self.publish(topic:, payload:, partition_key:)
    KAFKA_PRODUCER.produce_sync(
      topic:         topic,
      payload:       payload.to_json,
      partition_key: partition_key.to_s
    )
  rescue WaterDrop::Errors::ProducerNotStartedError => e
    Rails.logger.error("[KafkaProducer] Producer not started: #{e.message}")
    raise
  rescue StandardError => e
    Rails.logger.error("[KafkaProducer] Failed to publish to #{topic}: #{e.message}")
    raise
  end
end
