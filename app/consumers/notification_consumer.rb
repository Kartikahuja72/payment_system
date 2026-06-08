class NotificationConsumer < ApplicationConsumer
  private

  def process(payload)
    event_type = payload["event_type"]
    payment_id = payload["payment_id"]

    payment = Payment.find_by(id: payment_id)

    unless payment
      Rails.logger.warn("[NotificationConsumer] Payment #{payment_id} not found — skipping notification")
      return
    end

    unless payment.email.present?
      Rails.logger.info("[NotificationConsumer] Payment #{payment_id} has no email — skipping notification")
      return
    end

    case event_type
    when "payment_captured"
      PaymentMailer.payment_captured_email(payment).deliver_now
      Rails.logger.info("[NotificationConsumer] Sent payment_captured email to #{payment.email} | payment=#{payment.id}")

    when "payment_failed"
      PaymentMailer.payment_failed_email(
        payment,
        error_message: payload["error_message"]
      ).deliver_now
      Rails.logger.info("[NotificationConsumer] Sent payment_failed email to #{payment.email} | payment=#{payment.id}")

    when "refund_processed"
      PaymentMailer.refund_processed_email(
        payment,
        refund_amount: payload["refund_amount"] || payment.amount
      ).deliver_now
      Rails.logger.info("[NotificationConsumer] Sent refund_processed email to #{payment.email} | payment=#{payment.id}")

    else
      Rails.logger.warn("[NotificationConsumer] Unknown event_type=#{event_type} for payment #{payment.id}")
    end
  rescue => e
    Rails.logger.error("[NotificationConsumer] Failed to send notification: #{e.message}")
    raise
  end
end
