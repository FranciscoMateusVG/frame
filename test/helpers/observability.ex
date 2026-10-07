defmodule Frame.Test.Observability do
  @moduledoc """
  Test helper — an Observability backed by an in-memory span exporter for
  asserting on emitted spans.

  Delegates to the exported consumer helper `Frame.Testing.Observability`,
  so Frame's own tests exercise exactly what consumers get. This (and
  `Frame.Testing`) is the only place Frame's tests touch the OTel SDK for
  traces. Production code only sees the API, which is no-op safe by default.

      test_obs = Frame.Test.Observability.create_test_observability()
      # ... run code under test ...
      [%{name: "createCat"} | _] = Frame.Test.Observability.get_spans(test_obs)
  """

  alias Frame.Testing.Observability, as: TestingObservability

  defdelegate create_test_observability(), to: TestingObservability
  defdelegate get_spans(test_obs), to: TestingObservability
  defdelegate reset(test_obs), to: TestingObservability
  defdelegate shutdown(test_obs), to: TestingObservability

  @doc "Finds a span by name in a list of finished spans."
  def find_span(spans, name), do: Enum.find(spans, &(&1.name == name))

  @doc "True if the span recorded an `exception` event."
  def exception_event?(span), do: Enum.any?(span.events, &(&1.name == "exception"))
end
