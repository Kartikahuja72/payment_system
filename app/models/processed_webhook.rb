class ProcessedWebhook < ApplicationRecord
  validates :event_id, :source, presence: true
  validates :event_id, uniqueness: { scope: :source }
end


# Gateways retry webhooks. If your server returns 200, they stop. If you're slow or have a bug, they retry every few minutes for hours. Without this table, a payment could be captured 5 times — once per webhook delivery.
# The WebhookReceivedConsumer checks this table before processing. If a row already exists, it skips. After processing, it inserts a row. The unique index on [:event_id, :source] ensures that even if two Karafka consumers race and both try to process the same webhook simultaneously, only one succeeds — the other gets RecordNotUnique and skips.
