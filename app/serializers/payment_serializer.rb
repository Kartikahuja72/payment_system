class PaymentSerializer < ActiveModel::Serializer
  attributes :id,
            :order_id,
            :amount,
            :currency,
            :status,
            :gateway,
            :gateway_payment_id,
            :payment_method,
            :email,
            :trace_id,
            :lock_version,
            :created_at,
            :updated_at
end
