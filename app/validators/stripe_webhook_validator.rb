class StripeWebhookValidator
  def initialize(raw_body, signature)
    @raw_body  = raw_body
    @signature = signature
  end

  def valid?
    return false if @signature.blank?

    secret = ENV.fetch("STRIPE_WEBHOOK_SECRET")
    Stripe::Webhook.construct_event(@raw_body, @signature, secret)
    true
  rescue Stripe::SignatureVerificationError
    false
  end

  def event
    return @event if defined?(@event)

    secret  = ENV.fetch("STRIPE_WEBHOOK_SECRET")
    @event  = Stripe::Webhook.construct_event(@raw_body, @signature, secret)
  rescue Stripe::SignatureVerificationError
    nil
  end
end
