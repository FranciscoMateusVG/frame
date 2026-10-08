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
