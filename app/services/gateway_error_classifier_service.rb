module GatewayErrorClassifierService
  RETRYABLE_ERRORS = %i[
    timeout
    network_error
    bad_gateway
    service_unavailable
    gateway_timeout
    too_many_requests
  ].freeze

  NON_RETRYABLE_ERRORS = %i[
    invalid_card
    insufficient_funds
    invalid_cvv
    card_expired
    auth_failure
    card_blocked
    invalid_account
    do_not_honor
  ].freeze

  def self.retryable?(error_code)
    RETRYABLE_ERRORS.include?(error_code.to_sym)
  end

  def self.non_retryable?(error_code)
    NON_RETRYABLE_ERRORS.include?(error_code.to_sym)
  end

  def self.should_retry?(error_code)
    !non_retryable?(error_code)
  end
end
