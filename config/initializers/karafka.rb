# WaterDrop is Karafka's producer library. We configure it directly here
# so KafkaProducer.publish works inside Rails (Puma, Resque) without
# needing to run `karafka server`.
# The full KarafkaApp (routes + consumers) is only used by `karafka server`.

KAFKA_PRODUCER = WaterDrop::Producer.new do |config|
  config.kafka = {
    'bootstrap.servers': ENV.fetch("KAFKA_BROKERS") { "localhost:9092" }
  }
  config.logger = Rails.logger
end
