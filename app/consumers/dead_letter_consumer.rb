class DeadLetterConsumer < ApplicationConsumer
  private

  def process(payload)
    # Persist every dead-lettered message so nothing is silently lost.
    # Messages land here after exhausting all retries on the source topic.
    DeadLetterEvent.create!(
      topic:          message.topic,
      partition:      message.partition,
      offset:         message.offset,
      payload:        payload,
      error_message:  payload["error_message"],
      consumer_class: payload["consumer_class"] || "unknown"
    )

    Rails.logger.error(
      "[DeadLetterConsumer] Persisted dead letter | " \
      "topic=#{message.topic} partition=#{message.partition} offset=#{message.offset} | " \
      "payload=#{payload.to_json.truncate(200)}"
    )
  rescue => e
    Rails.logger.error("[DeadLetterConsumer] Failed to persist dead letter: #{e.message}")
    # Do NOT raise — re-raising here would cause infinite DLQ loop.
    # ApplicationConsumer commits the offset after process returns regardless.
  end
end
