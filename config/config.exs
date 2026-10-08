import Config

# Access and business logs: the message plus the structured attributes the
# portal emits (never bodies, tokens, cookies or file names).
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :method,
    :route,
    :status,
    :duration_ms,
    :operation,
    :orderId,
    :competence,
    :otel_trace_id
  ]

# Elixir's built-in JSON; no Jason in the release.
config :phoenix, :json_library, JSON

# Phoenix's own logger prints request/socket/LiveView params (passwords are
# filtered, but amounts, CSRF tokens and file names are not): off. The
# portal logs one access line per request (Frame.Web.Edge) and business
# events from the use cases.
config :phoenix, :logger, false

# Static endpoint configuration only. Port, URL, check_origin, the secret
# and the dependency map are start arguments (Frame.Application).
config :frame, Frame.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: Frame.PubSub,
  render_errors: [formats: [html: Frame.Web.ErrorHTML, json: Frame.Web.ErrorJSON], layout: false],
  live_view: [signing_salt: "print-portal-live"]

if config_env() == :test do
  config :phoenix_live_view, :test_warnings, missing_form_id: :raise
end
