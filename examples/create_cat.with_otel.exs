# Example: Create a Cat with full OpenTelemetry tracing.
#
# This is the canonical documentation for how consumers wire up OTel with Frame.
# It demonstrates the complete SDK setup that Frame deliberately does NOT do for you:
# - the `opentelemetry` SDK application with a simple processor + stdout exporter
# - global provider registration (starting the SDK application)
# - create_cat producing a parent span with a nested db.cats.save child span
#
# Spans are printed to stdout, proving the instrumentation works end-to-end.
# In production, replace the stdout exporter with OTLP (in config/runtime.exs):
#
#   {:opentelemetry_exporter, "~> 1.8"}
#   config :opentelemetry, traces_exporter: :otlp
#   config :opentelemetry_exporter, otlp_endpoint: "http://localhost:4318"
#
# For Honeycomb, Datadog, Grafana, etc. — consult their OTel integration docs.
# Frame doesn't abstract exporter choice; you own your observability pipeline.
#
# Usage: MIX_ENV=test mix run examples/create_cat.with_otel.exs

alias Frame.Adapters.CatRepository
alias Frame.Adapters.CatRepository.Postgres
alias Frame.Observability.{ConsoleLogger, Observability}
alias Frame.Test.TestDb

# --- Step 1: Set up the OTel SDK (consumer's responsibility, not Frame's) ---

# Starting the SDK application does two things:
# 1. Registers the global TracerProvider (adapters' application tracer becomes real)
# 2. Enables process-local context propagation for parent-child span nesting
Application.put_env(:opentelemetry, :span_processor, :simple)
Application.put_env(:opentelemetry, :traces_exporter, {:otel_exporter_stdout, []})
{:ok, _} = Application.ensure_all_started(:opentelemetry)

# Get a tracer for the use case layer
tracer = :opentelemetry.get_tracer(:"frame-example")

IO.puts("🐱 Frame Example: Create a Cat (with OpenTelemetry)")
IO.puts("====================================================")
IO.puts("")
IO.puts("Spans will be printed to stdout by the stdout exporter.")
IO.puts("Look for: createCat (parent) → db.cats.save (child)")
IO.puts("")

# --- Step 2: Start the app (same as any Frame consumer) ---

test_db = TestDb.create_test_database()

try do
  cat_repository = Postgres.new(test_db.db)

  deps = %{
    cat_repository: cat_repository,
    clock: &DateTime.utc_now/0,
    observability: %Observability{logger: ConsoleLogger.new(), tracer: tracer}
  }

  # Create a cat — this produces a createCat span with a child db.cats.save span
  {:ok, cat} = Frame.create_cat(deps, %{id: Ecto.UUID.generate(), name: "Whiskers"})
  IO.puts("")
  IO.puts("✅ Created cat: #{inspect(cat)}")

  # Fetch it back — produces a db.cats.findById span
  fetched = CatRepository.find_by_id(cat_repository, cat.id)
  IO.puts("✅ Fetched cat: #{inspect(fetched)}")

  # Delete it — produces a db.cats.deleteById span
  deleted = CatRepository.delete_by_id(cat_repository, cat.id)
  IO.puts("✅ Deleted cat: #{inspect(deleted)}")

  IO.puts("")
  IO.puts("🎉 Example completed successfully! Check the span output above.")
after
  # Flush any remaining spans and shut down the provider
  :otel_tracer_provider.force_flush()
  Application.stop(:opentelemetry)
  TestDb.teardown(test_db)
end
