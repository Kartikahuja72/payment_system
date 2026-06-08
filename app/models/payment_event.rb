class PaymentEvent < ApplicationRecord
  belongs_to :payment

  # Immutable — never allow updates or deletes
  before_update { raise "PaymentEvent records are immutable" }
  before_destroy { raise "PaymentEvent records are immutable" }
end
