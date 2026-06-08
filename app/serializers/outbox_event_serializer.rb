class OutboxEventSerializer < ActiveModel::Serializer
  attributes :id, :event_type, :status, :retry_count, :published_at, :created_at
end
