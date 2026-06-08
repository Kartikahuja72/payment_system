module GatewayRetryEngineService
  DELAYS      = [1, 5, 30, 120, 600].freeze
  MAX_RETRIES = DELAYS.size

  def self.next_delay(retry_count)
    base   = DELAYS[retry_count] || DELAYS.last
    jitter = base * rand(0.1)
    (base + jitter).round(2)
  end

  def self.max_retries_exceeded?(retry_count)
    retry_count >= MAX_RETRIES
  end
end
