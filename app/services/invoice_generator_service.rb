class InvoiceGeneratorService
  def initialize(payment:)
    @payment = payment
  end

  def call
    # Idempotent — return existing invoice if already created for this payment
    existing = Invoice.find_by(payment_id: @payment.id)
    return existing if existing

    Invoice.create!(
      payment_id:     @payment.id,
      invoice_number: generate_invoice_number,
      amount:         @payment.amount,
      currency:       @payment.currency,
      status:         "issued",
      issued_at:      Time.current
    )
  rescue ActiveRecord::RecordNotUnique
    Invoice.find_by!(payment_id: @payment.id)
  end

  private

  def generate_invoice_number
    date_part = Time.current.strftime("%Y%m%d")
    id_part   = @payment.id.to_s.rjust(8, "0")
    "INV-#{date_part}-#{id_part}"
  end
end
