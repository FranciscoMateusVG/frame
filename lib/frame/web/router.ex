defmodule Frame.Web.Router do
  @moduledoc """
  Routes of the portal (spec §4.5):

    * `GET /healthz` (liveness) and `GET /readyz` (upstream answers with the
      service token);
    * `/api/session` and the ten `/api/print/v1/...` service routes (JSON,
      common to the TS/Rust/Elixir portals);
    * `/login` and `/logout` (controllers: they set and drop cookies);
    * the supplier pages as LiveViews: `/orders`, `/orders/:id`,
      `/invoices`.

  Every other path or method is answered by `FallbackController` (404, or
  405 with `Allow` on a known path) — JSON under `/api`, HTML elsewhere.
  """

  use Phoenix.Router, helpers: false

  import Phoenix.LiveView.Router

  alias Frame.Web.BrowserSession

  @session_options Frame.Web.SessionCookieStore.options()

  pipeline :browser do
    plug :put_root_layout, html: {Frame.Web.Layouts, :root}
    plug Plug.Session, @session_options
    plug :fetch_session
    plug BrowserSession, :fetch
  end

  pipeline :signed_in do
    plug BrowserSession, :require
  end

  pipeline :api do
    plug Frame.Web.ApiGuard
  end

  scope "/", Frame.Web do
    get "/version", HealthController, :version
    get "/healthz", HealthController, :live
    get "/readyz", HealthController, :ready
  end

  scope "/api", Frame.Web do
    pipe_through :api

    get "/session", SessionController, :show
    post "/session", SessionController, :create
    delete "/session", SessionController, :delete

    scope "/print/v1" do
      get "/orders", PrintController, :list_orders
      get "/orders/:id", PrintController, :get_order
      get "/orders/:id/files/:file_id", PrintController, :order_file
      post "/orders/:id/collected", PrintController, :collected
      post "/orders/:id/quotes", PrintController, :submit_quote
      get "/orders/:id/quotes/:quote_id/file", PrintController, :quote_file
      post "/orders/:id/printed", PrintController, :printed
      get "/monthly-closes/:competence", PrintController, :monthly_close
      get "/monthly-closes/:competence/invoice", PrintController, :invoice_file
      post "/monthly-closes/:competence/invoice", PrintController, :submit_invoice
    end

    match :*, "/*path", FallbackController, :api
  end

  scope "/", Frame.Web do
    pipe_through :browser

    get "/", LoginController, :root
    get "/login", LoginController, :new
    post "/login", LoginController, :create
    post "/logout", LoginController, :delete

    scope "/" do
      pipe_through :signed_in

      live_session :portal, on_mount: Frame.Web.LiveAuth do
        live "/orders", OrdersLive
        live "/orders/:id", OrderLive
        live "/invoices", InvoicesLive
      end
    end

    match :*, "/*path", FallbackController, :html
  end
end
