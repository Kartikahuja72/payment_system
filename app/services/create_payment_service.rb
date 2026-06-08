class CreatePaymentService
  Result = Struct.new(:success?, :payment, :error, keyword_init: true)

  def initialize(params:, idempotency_key:, trace_id:)
    @params          = params
    @idempotency_key = idempotency_key
    @trace_id        = trace_id
  end

  def call
    ActiveRecord::Base.transaction do
      payment = Payment.create!(
        order_id:        @params[:order_id],
        amount:          @params[:amount],
        currency:        @params.fetch(:currency, "INR"),
        payment_method:  @params[:payment_method],
        gateway:         @params.fetch(:gateway, "razorpay"),
        email:           @params[:email],
        idempotency_key: @idempotency_key,
        trace_id:        @trace_id
      )

      saga_id = SecureRandom.uuid

      # Start saga — tracks the full multi-step flow for this payment
      SagaTransaction.create!(
        saga_id:         saga_id,
        payment_id:      payment.id,
        current_step:    "inventory_reserve",
        status:          "running",
        steps_completed: [],
        metadata:        { started_at: Time.current.iso8601 }
      )

      # Write payment.created outbox — OutboxWorkerJob publishes to Kafka
      # DB rollback removes both rows together — no inconsistency possible
      OutboxEvent.create!(
        aggregate_type: "Payment",
        aggregate_id:   payment.id,
        event_type:     "payment.created",
        payload:        {
          payment_id:     payment.id,
          order_id:       payment.order_id,
          amount:         payment.amount,
          currency:       payment.currency,
          payment_method: payment.payment_method,
          gateway:        payment.gateway,
          trace_id:       @trace_id,
          event_id:       SecureRandom.uuid
        }
      )

      # Write inventory.reserve outbox — Step 1 of the saga
      # OutboxWorkerJob publishes this to the inventory.reserve Kafka topic
      OutboxEvent.create!(
        aggregate_type: "Payment",
        aggregate_id:   payment.id,
        event_type:     "inventory.reserve",
        payload:        {
          saga_id:    saga_id,
          payment_id: payment.id,
          order_id:   payment.order_id,
          amount:     payment.amount,
          currency:   payment.currency,
          trace_id:   @trace_id,
          event_id:   SecureRandom.uuid
        }
      )

      Result.new(success?: true, payment: payment, error: nil)
    end
  rescue ActiveRecord::RecordNotUnique => e
    Result.new(success?: false, payment: nil, error: duplicate_error(e))
  rescue ActiveRecord::RecordInvalid => e
    Result.new(success?: false, payment: nil, error: e.message)
  end

  private

  def duplicate_error(exception)
    if exception.message.include?("idempotency_key")
      "Duplicate request: idempotency key already used"
    elsif exception.message.include?("order_id")
      "Payment already exists for this order"
    else
      "Duplicate record"
    end
  end
end
