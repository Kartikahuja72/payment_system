class DeadLetterEvent < ApplicationRecord
  validates :topic,          presence: true
  validates :consumer_class, presence: true
  validates :payload,        presence: true

  scope :recent, -> { order(created_at: :desc) }
end

# partition + offset — exact position in Kafka, so you can replay it later if needed
