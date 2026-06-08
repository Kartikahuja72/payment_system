class OutboxWorkerJob
  @queue = :outbox

  BATCH_SIZE = 100
  MAX_RETRIES = 5

  def self.perform
    OutboxEvent.pending.order(:created_at).limit(BATCH_SIZE).each do |event|
      publish(event)
    end
  end

  def self.publish(event)
    KafkaProducer.publish(
      topic:         event.event_type,
      payload:       event.payload,
      partition_key: event.aggregate_id
    )

    event.update!(status: "published", published_at: Time.current)
  rescue StandardError => e
    Rails.logger.error("[OutboxWorkerJob] Failed to publish event #{event.id}: #{e.message}")

    if event.retry_count + 1 >= MAX_RETRIES
      event.update!(status: "failed", retry_count: event.retry_count + 1)
      Rails.logger.error("[OutboxWorkerJob] Event #{event.id} exceeded max retries — marked failed")
    else
      event.increment!(:retry_count)
    end
  end
end
