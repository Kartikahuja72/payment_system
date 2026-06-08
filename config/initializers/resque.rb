Resque.redis = $redis

Rails.application.config.active_job.queue_adapter = :resque

# Load the schedule file for resque-scheduler
if defined?(Resque::Scheduler)
  Resque.schedule = YAML.load_file(Rails.root.join("config/resque_schedule.yml"))
end
