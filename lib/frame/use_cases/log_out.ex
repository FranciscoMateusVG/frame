defmodule Frame.UseCases.LogOut do
  @moduledoc """
  The `logOut` use case ("Sair", `DELETE /api/session`): revokes the session
  immediately. Repeating it, or calling it without a session, is a silent
  no-op that reveals nothing.
  """

  alias Frame.Adapters.SessionStore
  alias Frame.Observability.Logger
  alias Frame.Observability.Observability

  @type deps :: %{
          required(:session_store) => SessionStore.t(),
          required(:observability) => Observability.t(),
          optional(atom()) => term()
        }

  @doc "Revokes `session_id` (if any)."
  @spec log_out(deps(), String.t() | nil) :: :ok
  def log_out(deps, session_id) do
    %Observability{logger: logger, tracer: tracer} = deps.observability

    :otel_tracer.with_span(tracer, "logOut", %{}, fn span ->
      if session_id do
        SessionStore.revoke(deps.session_store, session_id)
        Logger.info(logger, "session.revoked", %{})
      end

      OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:ok))
      :ok
    end)
  end
end
