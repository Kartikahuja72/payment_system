class PaymentEventSerializer < ActiveModel::Serializer
  attributes :id, :event_type, :from_status, :to_status, :payload, :trace_id, :created_at
end
