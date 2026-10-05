# frozen_string_literal: true

ActiveDurable::Engine.routes.draw do
  root "executions#index"

  resources :executions, only: %i[index show], constraints: { id: %r{[^/]+} } do
    member do
      post :retry, action: :retry_now
      post :compensate
      post :rerun
    end
  end
end
