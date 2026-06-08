class GatewayWebhookLog < ApplicationRecord
  validates :source, :event_id, :event_type, :payload, :received_at, presence: true
  validates :source, inclusion: { in: %w[razorpay stripe] }

  before_update { raise "GatewayWebhookLog records are immutable" }
  before_destroy { raise "GatewayWebhookLog records are immutable" }
end
