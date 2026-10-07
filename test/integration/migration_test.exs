defmodule Frame.Integration.MigrationTest do
  use ExUnit.Case, async: false

  alias Frame.Adapters.Database
  alias Frame.Test.TestDb

  @moduletag timeout: 120_000

  setup_all do
    {container, uri} = TestDb.start_postgres_container()
    db = Database.create_database(uri)

    on_exit(fn ->
      Database.destroy(db)
      TestDb.stop_container(container)
    end)

    %{db: db}
  end

  defp table_names(db) do
    %{rows: rows} =
      Database.run(db, fn repo ->
        repo.query!(
          "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'"
        )
      end)

    List.flatten(rows)
  end

  defp migrate(db, direction, opts),
    do:
      Ecto.Migrator.run(
        Database.Repo,
        TestDb.migrations_path(),
        direction,
        [dynamic_repo: db.pool, log: false] ++ opts
      )

  describe "Migration round-trip" do
    test "should migrate up and down cleanly", %{db: db} do
      # Migrate up
      assert [_ | _] = applied = migrate(db, :up, all: true)
      assert length(applied) == length(Path.wildcard(Path.join(TestDb.migrations_path(), "*.exs")))

      # Verify cats table exists
      assert "cats" in table_names(db)

      # Migrate down (one step)
      assert [_] = migrate(db, :down, step: 1)

      # Verify cats table is gone
      refute "cats" in table_names(db)
    end
  end
end
