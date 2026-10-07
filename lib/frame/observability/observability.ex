defmodule Frame.Observability.Observability do
  @moduledoc """
  Observability — groups Logger and Tracer because they always travel together.

  Use cases accept this as a single dependency instead of separate logger and
  tracer arguments, preventing deps maps from ballooning as Frame grows.

  Adapters do NOT receive Observability. They use their application's tracer
  (`OpenTelemetry.Tracer` macros) and rely on OTel's process-local context
  propagation for automatic parent-child span nesting. See
  `.claude/CLAUDE.md` for the full instrumentation rules.

      %{
        cat_repository: repo,
        clock: &DateTime.utc_now/0,
        observability: %Frame.Observability.Observability{logger: logger, tracer: tracer}
      }
  """

  alias Frame.Observability.Logger
  alias Frame.Observability.Tracer

  @enforce_keys [:logger, :tracer]
  defstruct [:logger, :tracer]

  @type t :: %__MODULE__{logger: Logger.t(), tracer: Tracer.t()}
end
