# The same journey with the OpenTelemetry SDK registered (in-memory
# exporter), printing the span tree: HTTP adapter spans nest under the use
# case spans, and no span carries instructions, file names or secrets.
#
#   mix run --no-start examples/portal_journey.with_otel.exs   (MIX_ENV=test)

alias Frame.Adapters.PrintApi
alias Frame.Testing.Observability, as: TestObservability
alias Frame.UseCases

obs = TestObservability.create_test_observability()
api = PrintApi.Memory.new()

deps = %{print_api: api, clock: &DateTime.utc_now/0, observability: obs.observability}

order =
  PrintApi.Memory.seed_order(api, [
    %{
      title: "Apostila",
      copies: 2,
      instructions: "SECRET-INSTRUCTION",
      file_name: "SECRET-NAME.pdf",
      bytes: "%PDF-1.4 x"
    }
  ])

{:ok, _} = UseCases.ListOrders.list_orders(deps, %{})
{:ok, _} = UseCases.GetOrder.get_order(deps, order["id"])

spans = TestObservability.get_spans(obs)
by_id = Map.new(spans, &{&1.span_id, &1})

for span <- spans do
  parent = by_id[span.parent_span_id]
  IO.puts("#{span.name}#{if parent, do: "  ⟵ #{parent.name}", else: ""}")
end

dump = inspect(spans, limit: :infinity, printable_limit: :infinity)
false = dump =~ "SECRET"

true =
  Enum.any?(
    spans,
    &(&1.name == "http.print_api.getOrder" and by_id[&1.parent_span_id].name == "getOrder")
  )

IO.puts("#{length(spans)} spans, no content in telemetry.")
TestObservability.shutdown(obs)
