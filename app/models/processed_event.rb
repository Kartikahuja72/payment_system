class ProcessedEvent < ApplicationRecord
  validates :event_id, :consumer, :topic, presence: true
  validates :event_id, uniqueness: { scope: :consumer }
end
