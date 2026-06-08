class TraceIdMiddleware
  HEADER_IN  = "HTTP_X_TRACE_ID"
  HEADER_OUT = "X-Trace-Id"

  def initialize(app)
    @app = app
  end

  def call(env)
    trace_id = env[HEADER_IN].presence || SecureRandom.uuid
    env["payment.trace_id"] = trace_id

    # Make it accessible via a thread-local so models and services can read it
    # without passing it explicitly through every call frame
    Thread.current[:trace_id] = trace_id

    status, headers, body = @app.call(env)
    headers[HEADER_OUT] = trace_id
    [status, headers, body]
  ensure
    Thread.current[:trace_id] = nil
  end
end
