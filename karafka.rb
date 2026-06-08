class KarafkaApp < Karafka::App
  setup do |config|
    config.kafka = {
      'bootstrap.servers': ENV.fetch("KAFKA_BROKERS") { "localhost:9092" }
    }
    config.client_id        = "payment_system"
    config.concurrency      = 5
    config.max_wait_time    = 1_000
    config.shutdown_timeout = 60_000
  end

  # Shared topic config — 6 partitions so all events for same payment_id
  # land in the same partition (ordering guarantee per payment)
  TOPIC_CONFIG = { partitions: 6, replication_factor: 1 }.freeze

  routes.draw do
    topic "payment.created" do
      consumer PaymentCreatedConsumer
      dead_letter_queue(topic: "deadletter.payment", max_retries: 5)
      config(**TOPIC_CONFIG)
    end

    topic "payment.processing" do
      consumer PaymentProcessingConsumer
      dead_letter_queue(topic: "deadletter.payment", max_retries: 5)
      config(**TOPIC_CONFIG)
    end

    topic "payment.authorized" do
      consumer PaymentAuthorizedConsumer
      dead_letter_queue(topic: "deadletter.payment", max_retries: 5)
      config(**TOPIC_CONFIG)
    end

    topic "payment.failed" do
      consumer PaymentFailedConsumer
      dead_letter_queue(topic: "deadletter.payment", max_retries: 5)
      config(**TOPIC_CONFIG)
    end

    topic "payment.refund" do
      consumer PaymentRefundConsumer
      dead_letter_queue(topic: "deadletter.payment", max_retries: 5)
      config(**TOPIC_CONFIG)
    end

    topic "payment.webhook.received" do
      consumer WebhookReceivedConsumer
      dead_letter_queue(topic: "deadletter.payment", max_retries: 5)
      config(**TOPIC_CONFIG)
    end

    topic "ledger.entry.created" do
      consumer LedgerEntryConsumer
      dead_letter_queue(topic: "deadletter.payment", max_retries: 5)
      config(**TOPIC_CONFIG)
    end

    topic "notification.send" do
      consumer NotificationConsumer
      dead_letter_queue(topic: "deadletter.payment", max_retries: 5)
      config(**TOPIC_CONFIG)
    end

    topic "reconciliation.required" do
      consumer ReconciliationConsumer
      dead_letter_queue(topic: "deadletter.payment", max_retries: 5)
      config(**TOPIC_CONFIG)
    end

    # ── Saga topics ────────────────────────────────────────────────────────────

    topic "inventory.reserve" do
      consumer InventoryReserveConsumer
      dead_letter_queue(topic: "deadletter.payment", max_retries: 5)
      config(**TOPIC_CONFIG)
    end

    topic "invoice.create" do
      consumer InvoiceConsumer
      dead_letter_queue(topic: "deadletter.payment", max_retries: 5)
      config(**TOPIC_CONFIG)
    end

    # ── Dead letter — no DLQ on the DLQ itself (would loop forever) ───────────
    topic "deadletter.payment" do
      consumer DeadLetterConsumer
      config(partitions: 1, replication_factor: 1)
    end

  end
end
