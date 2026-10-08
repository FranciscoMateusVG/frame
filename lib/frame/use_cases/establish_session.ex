defmodule Frame.UseCases.EstablishSession do
  @moduledoc """
  The `establishSession` use case (`GET /api/session`): reports whether the
  caller is logged in and hands out the CSRF token to use next. A caller
  without a live session gets a pre-session — the record that binds the
  login form's CSRF token. A pre-session never grants access.
  """

  alias Frame.Adapters.SessionStore
  alias Frame.Domain.Session
  alias Frame.Observability.Observability

  @type deps :: %{
          required(:session_store) => SessionStore.t(),
          required(:observability) => Observability.t(),
          optional(atom()) => term()
        }

  @type input :: %{session_id: String.t() | nil, pre_session_id: String.t() | nil}

  @type result ::
          {:authenticated, Session.t()}
          | {:anonymous, Session.t(), :existing | :created}

  @doc "Resolves the caller's session, creating a pre-session if needed."
  @spec establish_session(deps(), input()) :: {:ok, result()}
  def establish_session(deps, input) do
    %Observability{tracer: tracer} = deps.observability
    store = deps.session_store

    :otel_tracer.with_span(tracer, "establishSession", %{}, fn span ->
      result =
        with :error <- fetch(store, input.session_id, :authenticated),
             :error <- fetch(store, input.pre_session_id, :pre) do
          {:anonymous, SessionStore.create(store, :pre), :created}
        else
          {:ok, %Session{authenticated: true} = s} -> {:authenticated, s}
          {:ok, %Session{} = pre} -> {:anonymous, pre, :existing}
        end

      OpenTelemetry.Span.set_attribute(
        span,
        :"session.authenticated",
        elem(result, 0) == :authenticated
      )

      OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:ok))
      {:ok, result}
    end)
  end

  defp fetch(_store, nil, _kind), do: :error
  defp fetch(store, id, kind), do: SessionStore.fetch(store, id, kind)
end
