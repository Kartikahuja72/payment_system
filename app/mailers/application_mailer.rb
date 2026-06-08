class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAILER_FROM") { "noreply@paymentapp.com" }
  layout "mailer"
end
