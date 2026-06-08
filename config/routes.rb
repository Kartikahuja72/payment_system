Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  resources :payments, only: [:create, :show] do
    member do
      post :refund
    end
  end

  post "webhooks/razorpay", to: "webhooks#razorpay"
  post "webhooks/stripe",   to: "webhooks#stripe"
end
