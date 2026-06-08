class PaymentDetailSerializer < ActiveModel::Serializer
  attributes :id,
             :order_id,
             :amount,
             :currency,
             :status,
             :gateway,
             :gateway_payment_id,
             :payment_method,
             :trace_id,
             :lock_version,
             :created_at,
             :updated_at

  has_many :payment_events,   serializer: PaymentEventSerializer
  has_many :ledger_entries,   serializer: LedgerEntrySerializer
  has_many :outbox_events,    serializer: OutboxEventSerializer
  has_many :processed_events, serializer: ProcessedEventSerializer
end
