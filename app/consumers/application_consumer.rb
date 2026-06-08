class ApplicationConsumer < Karafka::BaseConsumer
  # Enforces the golden rule for all consumers:
  #   consume → persist result → commit offset
  # Never commit offset before persisting — if the process crashes after
  # commit but before persist, the message is silently lost forever.

  def consume
    messages.each do |message|
      payload  = message.payload
      event_id = payload["event_id"]

      next if already_processed?(event_id)

      process(payload)
      mark_as_processed!(event_id, message.topic)

      # Offset commit happens after both process + DB write succeed.
      # If process or mark_as_processed raise, offset is NOT committed
      # and Kafka will redeliver — safe to retry.
      mark_as_consumed!(message)
    end
  end

  private

  # Subclasses implement this with their actual business logic
  def process(_payload)
    raise NotImplementedError, "#{self.class}#process must be implemented"
  end

  def already_processed?(event_id)
    return false if event_id.blank?

    ProcessedEvent.exists?(event_id: event_id, consumer: self.class.name)
  end

  def mark_as_processed!(event_id, topic)
    return if event_id.blank?

    ProcessedEvent.create!(
      event_id: event_id,
      consumer: self.class.name,
      topic:    topic
    )
  rescue ActiveRecord::RecordNotUnique
    # Another worker already processed this — safe to ignore
  end
end
