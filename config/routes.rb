Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token
  resources :invitations, only: %i[edit update], param: :token
  namespace :webhooks do
    post :stripe, to: "stripe#create"
  end

  get "/404", to: "errors#not_found", as: :not_found
  get "/422", to: "errors#unprocessable_entity"
  get "/500", to: "errors#internal_server_error"

  root "dashboard#index"

  get "accounts", to: "accounts#index", as: :accounts
  resources :owners, controller: :accounts, except: %i[destroy]

  resources :vessels do
    delete :primary_photo, on: :member, action: :destroy_primary_photo
    resources :service_visits, only: %i[index new create show] do
      get :report, on: :member
    end
    resources :documents, only: %i[new create destroy]
    resources :binder_notes, only: %i[create edit update destroy]
    resources :batteries, controller: :asset_batteries, except: %i[index show]
  end

  resources :documents, only: %i[index show new create edit update destroy]
  resources :reminders, only: %i[index new create edit update]
  resources :service_visits, only: %i[index]
  get "users", to: redirect("/admin/users")

  namespace :admin do
    resources :users, except: %i[show destroy] do
      post :resend_invitation, on: :member
    end
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
