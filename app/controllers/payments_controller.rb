class PaymentsController < ApplicationController
  before_action :require_idempotency_key, only: [:create, :refund]

  def create
    result = CreatePaymentService.new(
      params:          payment_params,
      idempotency_key: idempotency_key,
      trace_id:        current_trace_id
    ).call

    if result.success?
      render json: result.payment, serializer: PaymentSerializer, status: :created
    else
      render json: { error: result.error }, status: :unprocessable_entity
    end
  end

  def show
    payment = Payment
                .includes(:payment_events, :outbox_events)
                .find(params[:id])
    render json: payment, serializer: PaymentDetailSerializer
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Payment not found" }, status: :not_found
  end

  def refund
    payment = Payment.find(params[:id])

    result = ProcessRefundService.new(
      payment:         payment,
      idempotency_key: idempotency_key,
      trace_id:        current_trace_id
    ).call

    if result.success?
      render json: result.payment, serializer: PaymentSerializer
    else
      render json: { error: result.error }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Payment not found" }, status: :not_found
  end

  private

  def payment_params
    params.require(:payment).permit(:order_id, :amount, :currency, :payment_method, :gateway, :email)
  end

  def idempotency_key
    request.headers["Idempotency-Key"]
  end

  def current_trace_id
    Thread.current[:trace_id] || request.headers["X-Trace-Id"] || SecureRandom.uuid
  end

  def require_idempotency_key
    return if idempotency_key.present?
    render json: { error: "Idempotency-Key header is required" }, status: :bad_request
  end
end
