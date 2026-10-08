defmodule Frame.Application do
  @moduledoc """
  OTP application and composition root of the print portal.

  When `config :frame, serve: true` (production release, set in
  `config/runtime.exs`), it reads `Frame.Config` from the environment —
  refusing to start on any missing/invalid value — and starts:

    1. the Finch pool for the Incluir API origin,
    2. the session table owner and the login limiter,
    3. Bandit serving `Frame.Http.Router` with the dependency map.

  This is the only module that names concrete adapters. Tests and examples
  build their own dependency maps (`deps/2`) with the in-memory fake.
  """

  use Application

  alias Frame.Adapters.LoginLimiter
  alias Frame.Adapters.PrintApi
  alias Frame.Adapters.SessionStore
  alias Frame.Config
  alias Frame.Observability.Observability
  alias Frame.Observability.OtelLogger

  @finch Frame.Finch
  @sessions :frame_sessions
  @limiter Frame.LoginLimiter

  @impl true
  def start(_type, _args) do
    children = if Application.get_env(:frame, :serve, false), do: serve(), else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: Frame.Supervisor)
  end

  defp serve, do: System.get_env() |> load_config!() |> children()

  @doc """
  Reads the configuration from `env` or raises — printing each problem (by
  variable name, never its value) to stderr.
  """
  @spec load_config!(%{String.t() => String.t()}) :: Config.t()
  def load_config!(env) do
    case Config.from_env(env) do
      {:ok, config} ->
        config

      {:error, errors} ->
        Enum.each(errors, &IO.puts(:stderr, "print portal configuration error: " <> &1))
        raise "print portal configuration is invalid; refusing to start"
    end
  end

  @doc "The supervised children serving `config` (the production wiring)."
  @spec children(Config.t()) :: [Supervisor.child_spec() | {module(), term()}]
  def children(%Config{} = config) do
    session_opts = [table: @sessions, policy: config.session_policy]
    limiter_opts = [name: @limiter]

    deps =
      deps(config,
        print_api:
          PrintApi.Http.new(
            finch: @finch,
            origin: config.api_origin,
            token: config.service_token,
            timeout_ms: config.upstream_timeout_ms
          ),
        session_store: SessionStore.Memory.store(session_opts),
        login_limiter: LoginLimiter.Memory.handle(limiter_opts)
      )

    [
      {Finch, name: @finch, pools: %{config.api_origin => [size: 25, count: 1]}},
      %{id: SessionStore.Memory, start: {SessionStore.Memory, :start_link, [session_opts]}},
      {LoginLimiter.Memory, limiter_opts},
      {Bandit,
       plug: {Frame.Http.Router, deps},
       scheme: :http,
       port: config.port,
       thousand_island_options: [shutdown_timeout: 15_000]}
    ]
  end

  @doc """
  The dependency map handed to the router and use cases. `adapters` must
  provide `:print_api`, `:session_store` and `:login_limiter`; `:clock` and
  `:observability` may be overridden.
  """
  @spec deps(Config.t(), keyword()) :: map()
  def deps(%Config{} = config, adapters) do
    defaults = %{
      clock: &DateTime.utc_now/0,
      observability: %Observability{
        logger: OtelLogger.new("print-portal"),
        tracer: :opentelemetry.get_tracer(:frame)
      }
    }

    defaults
    |> Map.merge(Map.new(adapters))
    |> Map.merge(%{
      password: config.password,
      portal_origin: config.portal_origin,
      trusted_proxies: config.trusted_proxies
    })
  end
end
