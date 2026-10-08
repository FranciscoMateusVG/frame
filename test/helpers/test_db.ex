defmodule Frame.Test.TestDb do
  @moduledoc """
  Testcontainers helper — spins up a Postgres 16 container, runs migrations,
  and returns a connected `Frame.Adapters.Database`.

  Used by integration tests and examples for fully self-contained execution.
  """

  alias Ecto.Adapters.SQL.Sandbox
  alias Frame.Adapters.Database
  alias Testcontainers.PostgresContainer

  @migrations_path Path.expand("../../migrations", __DIR__)

  @enforce_keys [:db, :connection_uri, :container]
  defstruct [:db, :connection_uri, :container]

  @type t :: %__MODULE__{
          db: Database.t(),
          connection_uri: String.t(),
          container: Testcontainers.Container.t()
        }

  @suite_key {__MODULE__, :suite}

  @doc "Starts one container and a sandbox pool for the entire ExUnit run."
  def start_suite do
    base = create_test_database()

    {:ok, pool} =
      Database.Repo.start_link(
        url: base.connection_uri,
        name: nil,
        log: false,
        pool: Sandbox,
        pool_size: 20
      )

    sandbox = %{base | db: %Database{pool: pool}}
    Sandbox.mode(pool, :manual)
    :persistent_term.put(@suite_key, %{base: base, sandbox: sandbox})

    ExUnit.after_suite(fn _result ->
      :persistent_term.erase(@suite_key)
      Database.destroy(sandbox.db)
      teardown(base)
    end)
  end

  @doc "Checks out a per-test transaction; ownership ends after test children stop."
  def checkout do
    %{sandbox: db} = :persistent_term.get(@suite_key)
    owner = Sandbox.start_owner!(db.db.pool, shared: false)
    ExUnit.Callbacks.on_exit(fn -> Sandbox.stop_owner(owner) end)
    db
  end

  @doc "An isolated database on the shared server, for real DDL/connection races."
  def isolated_database(opts \\ []) do
    %{base: base} = :persistent_term.get(@suite_key)
    name = "frame_test_#{System.unique_integer([:positive])}"
    Database.run(base.db, & &1.query!(~s(CREATE DATABASE "#{name}")))
    uri = base.connection_uri |> URI.parse() |> Map.put(:path, "/" <> name) |> URI.to_string()
    db = Database.create_database(uri)
    Process.unlink(db.pool)

    if Keyword.get(opts, :migrate, true) do
      Ecto.Migrator.run(Database.Repo, @migrations_path, :up,
        all: true,
        dynamic_repo: db.pool,
        log: false
      )
    end

    ExUnit.Callbacks.on_exit(fn ->
      Database.destroy(db)
      Database.run(base.db, & &1.query!(~s(DROP DATABASE "#{name}")))
    end)

    %{base | db: db, connection_uri: uri}
  end

  @doc "Directory holding the Ecto migrations."
  @spec migrations_path() :: String.t()
  def migrations_path, do: @migrations_path

  @doc "Starts a fresh `postgres:16` container (the Testcontainers equivalent of `PostgreSqlContainer`)."
  @spec start_postgres_container() :: {Testcontainers.Container.t(), String.t()}
  def start_postgres_container do
    ensure_testcontainers_started()

    config =
      PostgresContainer.new()
      |> PostgresContainer.with_image("postgres:16")
      |> PostgresContainer.with_database("frame")
      |> PostgresContainer.with_user("frame")
      |> PostgresContainer.with_password("frame")

    {:ok, container} = Testcontainers.start_container(config)
    params = PostgresContainer.connection_parameters(container)

    uri =
      "postgres://#{params[:username]}:#{params[:password]}@#{params[:hostname]}:#{params[:port]}/#{params[:database]}"

    {container, uri}
  end

  @doc "Stops a container started by `start_postgres_container/0`."
  @spec stop_container(Testcontainers.Container.t()) :: :ok
  def stop_container(container) do
    Testcontainers.stop_container(container.container_id)
    :ok
  end

  @spec create_test_database() :: t()
  def create_test_database do
    {container, uri} = start_postgres_container()

    # Use create_database/1 — the same factory consumers use.
    db = Database.create_database(uri)

    try do
      Ecto.Migrator.run(Database.Repo, @migrations_path, :up,
        all: true,
        dynamic_repo: db.pool,
        log: false
      )
    rescue
      error ->
        Database.destroy(db)
        stop_container(container)
        reraise RuntimeError, "Migration failed: #{Exception.message(error)}", __STACKTRACE__
    end

    %__MODULE__{db: db, connection_uri: uri, container: container}
  end

  @spec teardown(t()) :: :ok
  def teardown(%__MODULE__{db: db, container: container}) do
    Database.destroy(db)
    stop_container(container)
  end

  @doc "Truncates the cats table (per-test isolation)."
  @spec truncate_cats(t()) :: :ok
  def truncate_cats(%__MODULE__{db: db}) do
    Database.run(db, & &1.query!("DELETE FROM cats"))
    :ok
  end

  defp ensure_testcontainers_started do
    # Quiet the readiness polling (one debug line every 200ms).
    Logger.put_application_level(:testcontainers, :info)

    case Testcontainers.start() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
