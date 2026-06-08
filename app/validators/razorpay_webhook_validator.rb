class RazorpayWebhookValidator
  def initialize(raw_body, signature)
    @raw_body  = raw_body
    @signature = signature
  end

  def valid?
    return false if @signature.blank?

    secret   = ENV.fetch("RAZORPAY_WEBHOOK_SECRET")
    expected = OpenSSL::HMAC.hexdigest("SHA256", secret, @raw_body)
    ActiveSupport::SecurityUtils.secure_compare(expected, @signature)
  end
end
