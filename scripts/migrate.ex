defmodule Mix.Tasks.Frame.Migrate do
  @shortdoc "Runs the migrations against DATABASE_URL (default: the docker compose DB)"
  @moduledoc "Applies all pending migrations in `migrations/` to `DATABASE_URL`."

  use Mix.Task

  alias Frame.Adapters.Database

  @default_url "postgresql://frame:frame@localhost:54320/frame"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    db = Database.create_database(System.get_env("DATABASE_URL", @default_url))

    try do
      applied =
        Ecto.Migrator.run(Database.Repo, "migrations", :up,
          all: true,
          dynamic_repo: db.pool,
          log: false
        )

      Enum.each(applied, &Mix.shell().info("✅ Migration \"#{&1}\" applied successfully."))
      Mix.shell().info("✅ All migrations applied.")
    rescue
      error ->
        Mix.shell().error("Migration failed: #{Exception.message(error)}")
        exit({:shutdown, 1})
    after
      Database.destroy(db)
    end
  end
end
