class InventoryReserveConsumer < ApplicationConsumer
  private

  def process(payload)
    saga_id    = payload["saga_id"]
    payment_id = payload["payment_id"]
    order_id   = payload["order_id"]

    saga = SagaTransaction.find_by(saga_id: saga_id)
    unless saga
      Rails.logger.warn("[InventoryReserveConsumer] SagaTransaction not found for saga_id=#{saga_id}")
      return
    end

    if simulate_inventory_check(order_id)
      saga.advance_to!("payment_processing", reserved_at: Time.current.iso8601)

      Rails.logger.info("[InventoryReserveConsumer] Inventory reserved | payment=#{payment_id} | saga=#{saga_id}")
    else
      saga.start_compensation!(reason: "inventory_unavailable")

      KafkaProducer.publish(
        topic:         "inventory.failed",
        payload:       {
          saga_id:    saga_id,
          payment_id: payment_id,
          order_id:   order_id,
          reason:     "inventory_unavailable",
          trace_id:   payload["trace_id"],
          event_id:   SecureRandom.uuid
        },
        partition_key: payment_id
      )

      Rails.logger.warn("[InventoryReserveConsumer] Inventory unavailable | payment=#{payment_id} | saga=#{saga_id}")
    end
  rescue => e
    Rails.logger.error("[InventoryReserveConsumer] Error: #{e.message}")
    raise
  end

  def simulate_inventory_check(_order_id)
    true
  end
end
