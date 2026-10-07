defmodule Mix.Tasks.Frame.CheckCodegenDrift do
  @shortdoc "Verifies the committed db_types.generated.ex matches the live schema"
  @moduledoc """
  Codegen drift check — spins up a Testcontainers Postgres, runs migrations,
  generates the schema module to a temp file, and diffs it against the
  committed file. Exits non-zero if they differ (or if migrations fail).
  """

  use Mix.Task

  alias Frame.Adapters.Database
  alias Mix.Tasks.Frame.DbCodegen
  alias Testcontainers.PostgresContainer

  @committed_path "lib/frame/adapters/db_types.generated.ex"
  @tmp_path "tmp/db_types.drift_check.ex"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    Mix.shell().info("🔍 Starting codegen drift check...")

    # 1. Start Testcontainers Postgres (quiet its readiness polling)
    Logger.put_application_level(:testcontainers, :info)
    {:ok, _} = Testcontainers.start_link()

    config =
      PostgresContainer.new()
      |> PostgresContainer.with_image("postgres:16")
      |> PostgresContainer.with_database("frame")
      |> PostgresContainer.with_user("frame")
      |> PostgresContainer.with_password("frame")

    {:ok, container} = Testcontainers.start_container(config)
    p = PostgresContainer.connection_parameters(container)
    url = "postgres://frame:frame@#{p[:hostname]}:#{p[:port]}/frame"
    Mix.shell().info("   Postgres container started at #{url}")

    try do
      check(url)
    after
      # Cleanup
      File.rm(@tmp_path)
      Testcontainers.stop_container(container.container_id)
    end
  end

  defp check(url) do
    # 2. Run migrations
    migrate!(url)
    Mix.shell().info("   Migrations applied.")

    # 3. Generate types to temp file
    File.mkdir_p!(Path.dirname(@tmp_path))
    File.write!(@tmp_path, DbCodegen.generate(url))
    Mix.shell().info("   Types generated to temp file.")

    # 4. Compare
    committed = @committed_path |> File.read!() |> String.trim()
    generated = @tmp_path |> File.read!() |> String.trim()

    if committed != generated do
      Mix.shell().error("""

      ❌ Codegen drift detected!
         The committed db_types.generated.ex does not match the live schema.
         Run `mix db.codegen` and commit the result.
      """)

      exit({:shutdown, 1})
    end

    Mix.shell().info("✅ No codegen drift. Committed types match live schema.")
  end

  defp migrate!(url) do
    db = Database.create_database(url)

    try do
      Ecto.Migrator.run(Database.Repo, "migrations", :up,
        all: true,
        dynamic_repo: db.pool,
        log: false
      )
    rescue
      error ->
        Mix.shell().error("❌ Migration failed: #{Exception.message(error)}")
        exit({:shutdown, 1})
    after
      Database.destroy(db)
    end
  end
end
