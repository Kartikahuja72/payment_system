class IdempotencyMiddleware
  IDEMPOTENCY_HEADER = "HTTP_IDEMPOTENCY_KEY"
  TTL_SECONDS        = 86_400  # 24 hours

  def initialize(app)
    @app = app
  end

  WEBHOOK_PATHS = %w[/webhooks/razorpay /webhooks/stripe].freeze

  def call(env)
    return @app.call(env) unless env["REQUEST_METHOD"] == "POST"

    # Webhooks come from gateways — they never send Idempotency-Key headers
    # and need the raw body untouched for signature validation
    return @app.call(env) if WEBHOOK_PATHS.include?(env["PATH_INFO"])

    key = env[IDEMPOTENCY_HEADER]
    return @app.call(env) if key.blank?

    redis_key = "idempotency:#{key}"
    cached    = $redis.get(redis_key)

    if cached
      payload = JSON.parse(cached)
      return [
        payload["status"],
        { "Content-Type" => "application/json", "X-Idempotency-Cache" => "HIT" },
        [payload["body"]]
      ]
    end

    status, headers, body = @app.call(env)

    # Cache only successful payment creations
    if status == 201
      body_string = body.respond_to?(:body) ? body.body : body.join
      $redis.setex(redis_key, TTL_SECONDS, JSON.generate(status: status, body: body_string))
    end

    [status, headers, body]
  end
end
