defmodule Frame.UseCases.LogIn do
  @moduledoc """
  The `logIn` use case (`POST /api/session`, HTML `/login`): checks the
  shared supplier password and opens a brand-new session.

    * Rate limits first (5 invalid / 15 min per client, 100 per instance):
      a blocked client gets `RATE_LIMITED` whatever the password.
    * The password is compared in constant time on SHA-256 digests.
    * Every wrong password gets the same answer (`INVALID_CREDENTIALS`).
    * On success the caller's pre-session (and any previous session) is
      revoked and a new session (new id, new CSRF token) is created —
      never a promoted pre-session.

  The CSRF/Origin checks of the request itself happen at the HTTP edge.
  Logs carry the outcome only — never the password, the client address or
  any token.
  """

  alias Frame.Adapters.LoginLimiter
  alias Frame.Adapters.SessionStore
  alias Frame.Domain.Session
  alias Frame.Errors.PortalError
  alias Frame.Observability.Logger
  alias Frame.Observability.Observability
  alias Frame.UseCases.UpstreamCall

  @type deps :: %{
          required(:session_store) => SessionStore.t(),
          required(:login_limiter) => LoginLimiter.t(),
          required(:password) => String.t(),
          required(:observability) => Observability.t(),
          optional(atom()) => term()
        }

  @typedoc "`revoke` lists the caller's previous session/pre-session ids (rotation)."
  @type input :: %{password: String.t(), client_ip: String.t(), revoke: [String.t()]}

  @doc "Logs in; returns the new authenticated session."
  @spec log_in(deps(), input()) :: {:ok, Session.t()} | {:error, PortalError.t()}
  def log_in(deps, input) do
    %Observability{logger: logger, tracer: tracer} = deps.observability

    :otel_tracer.with_span(tracer, "logIn", %{}, fn span ->
      with :ok <- LoginLimiter.check(deps.login_limiter, input.client_ip),
           true <- password_matches?(input.password, deps.password) do
        LoginLimiter.record_success(deps.login_limiter, input.client_ip)
        Enum.each(input.revoke, &SessionStore.revoke(deps.session_store, &1))
        session = SessionStore.create(deps.session_store, :authenticated)
        Logger.info(logger, "session.created", %{})
        OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:ok))
        {:ok, session}
      else
        {:blocked, retry_after} ->
          Logger.warn(logger, "session.login_rate_limited", %{})
          UpstreamCall.fail(span, PortalError.exception({:rate_limited, retry_after}))

        false ->
          LoginLimiter.record_failure(deps.login_limiter, input.client_ip)
          Logger.warn(logger, "session.login_rejected", %{})
          UpstreamCall.fail(span, PortalError.exception(:invalid_credentials))
      end
    end)
  end

  defp password_matches?(given, expected) do
    :crypto.hash_equals(:crypto.hash(:sha256, given), :crypto.hash(:sha256, expected))
  end
end
