class ProcessedEventSerializer < ActiveModel::Serializer
  attributes :id, :event_id, :consumer, :topic, :created_at
end
