defmodule Frame do
  @moduledoc """
  Print-shop portal for Incluir — public API surface.

  Elixir has no per-module export control, so the "public surface" is a
  convention, documented here and enforced by `mix frame.depcruise`:

    * **Domain:** `Frame.Domain.{Order, Close, Contract, Competence, Money,
      Document, Requests, Session, LoginThrottle}` (pure)
    * **Ports:** `Frame.Adapters.{PrintApi, SessionStore, LoginLimiter}`
    * **Errors:** `Frame.Errors.PortalError`
    * **Observability:** `Frame.Observability.{Logger, ConsoleLogger, NoopLogger,
      OtelLogger, Observability, Tracer}`
    * **Use cases:** `Frame.UseCases.*` (one module per use case)
    * **HTTP edge:** `Frame.Http.Router` (a Plug taking the dependency map)

  Concrete adapters are deliberately NOT surfaced here. The composition
  root (`Frame.Application`) is the only place that names them:

    * `Frame.Adapters.PrintApi.Http` / `Frame.Adapters.PrintApi.Memory`
    * `Frame.Adapters.SessionStore.Memory`, `Frame.Adapters.LoginLimiter.Memory`
    * `Frame.Testing.Observability` (≈ `frame/testing`)

  Nothing inside `lib/frame/` may depend on this module.
  """

  @doc "See `Frame.Observability.Tracer.noop_tracer/0`."
  @spec noop_tracer() :: Frame.Observability.Tracer.t()
  defdelegate noop_tracer(), to: Frame.Observability.Tracer
end
