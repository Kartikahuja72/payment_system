class InvoiceConsumer < ApplicationConsumer
  private

  def process(payload)
    payment = Payment.find(payload["payment_id"])

    invoice = InvoiceGeneratorService.new(payment: payment).call

    saga = SagaTransaction.find_by(payment_id: payment.id)
    saga&.advance_to!("invoice_creation", invoice_number: invoice.invoice_number)

    if payment.email.present?
      PaymentMailer.invoice_created_email(payment, invoice).deliver_now
      Rails.logger.info("[InvoiceConsumer] Invoice email sent to #{payment.email} | invoice=#{invoice.invoice_number}")
    end

    saga&.complete!

    Rails.logger.info("[InvoiceConsumer] Invoice #{invoice.invoice_number} created for payment #{payment.id} | saga complete")
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error("[InvoiceConsumer] Payment #{payload['payment_id']} not found")
    raise
  rescue => e
    Rails.logger.error("[InvoiceConsumer] Error: #{e.message}")
    raise
  end
end
