class PaymentMailer < ApplicationMailer
  def payment_captured_email(payment)
    @payment = payment
    mail(
      to:      @payment.email,
      subject: "Payment Confirmed — Order #{@payment.order_id}"
    )
  end

  # Sent immediately when the webhook confirms capture. "Your payment is confirmed." Quick receipt.

  def payment_failed_email(payment, error_message: nil)
    @payment       = payment
    @error_message = error_message
    mail(
      to:      @payment.email,
      subject: "Payment Failed — Order #{@payment.order_id}"
    )
  end

  # Sent by PaymentFailedConsumer via notification.send. Includes the error message so the customer knows why (e.g., "insufficient funds").

  def refund_processed_email(payment, refund_amount:)
    @payment       = payment
    @refund_amount = refund_amount
    mail(
      to:      @payment.email,
      subject: "Refund Processed — Order #{@payment.order_id}"
    )
  end

  # Sent when a refund webhook comes in. refund_amount is passed separately because partial refunds are possible — the refund amount may be less than payment.amount

  def invoice_created_email(payment, invoice)
    @payment = payment
    @invoice = invoice
    mail(
      to:      @payment.email,
      subject: "Your Invoice #{@invoice.invoice_number}"
    )
  end

  # Sent after the invoice is generated. Includes the invoice number so the customer has it for accounting. This is the "saga complete" email.
end
