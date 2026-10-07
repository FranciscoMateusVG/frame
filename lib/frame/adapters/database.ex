defmodule Frame.Adapters.Database do
  @moduledoc """
  Database handle — a connection pool (an Ecto repo instance) for one
  PostgreSQL connection string. Equivalent of the TypeScript
  `createDatabase(connectionString)` Kysely factory.

  The same factory is used by production consumers and by the test helpers,
  so there is no test-only database path.
  """

  defmodule Repo do
    @moduledoc false
    use Ecto.Repo, otp_app: :frame, adapter: Ecto.Adapters.Postgres
  end

  @enforce_keys [:pool]
  defstruct [:pool]

  @type t :: %__MODULE__{pool: pid()}

  @doc "Starts a connection pool for the given URL (linked to the caller)."
  @spec create_database(String.t()) :: t()
  def create_database(connection_string) when is_binary(connection_string) do
    {:ok, pool} = Repo.start_link(url: connection_string, name: nil, log: false)
    %__MODULE__{pool: pool}
  end

  @doc "Closes the pool."
  @spec destroy(t()) :: :ok
  def destroy(%__MODULE__{pool: pool}) do
    Supervisor.stop(pool, :normal)
  end

  @doc """
  Runs `fun` with the Ecto repo bound to this database's pool, restoring the
  previously bound pool afterwards. Adapters use this for every query.
  """
  @spec run(t(), (module() -> result)) :: result when result: term()
  def run(%__MODULE__{pool: pool}, fun) when is_function(fun, 1) do
    previous = Repo.put_dynamic_repo(pool)

    try do
      fun.(Repo)
    after
      Repo.put_dynamic_repo(previous)
    end
  end
end
