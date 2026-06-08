require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module PaymentSystem
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # Middleware files must be required explicitly because autoload hasn't run yet
    # when application.rb is evaluated
    require_relative "../app/middleware/trace_id_middleware"
    require_relative "../app/middleware/idempotency_middleware"

    # Middleware runs in order: TraceId first so trace_id is set before Idempotency reads Redis
    config.middleware.use TraceIdMiddleware
    config.middleware.use IdempotencyMiddleware

    config.autoload_paths += %W[
      #{config.root}/app/services
      #{config.root}/app/jobs
      #{config.root}/app/producers
      #{config.root}/app/consumers
      #{config.root}/app/gateways
      #{config.root}/app/validators
      #{config.root}/app/modules
    ]
  end
end
