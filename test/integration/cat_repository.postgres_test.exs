defmodule Frame.Integration.CatRepositoryPostgresTest do
  @moduledoc """
  Postgres adapter conformance + Postgres-specific behavior tests.

  The conformance suite (shared with the in-memory adapter) covers the core
  contract: save, find, delete, duplicate rejection, AND span emission. This
  file adds Postgres-specific tests: concurrency behavior under real database
  constraints.

  Test isolation: each test truncates the cats table, so any test can run in
  isolation and in any order. Testcontainers provides a fresh DB per module.
  """
  use ExUnit.Case, async: false

  alias Frame.Adapters.CatRepository
  alias Frame.Adapters.CatRepository.Postgres
  alias Frame.Errors.CatAlreadyExistsError
  alias Frame.Test.Observability, as: TestObs
  alias Frame.Test.TestDb

  @moduletag timeout: 120_000

  setup_all do
    test_obs = TestObs.create_test_observability()
    test_db = TestDb.create_test_database()

    on_exit(fn ->
      TestDb.teardown(test_db)
      TestObs.shutdown(test_obs)
    end)

    %{test_db: test_db, test_obs: test_obs}
  end

  # Conformance suite — same tests that run against the in-memory adapter.
  # Proves the Postgres adapter satisfies the same CatRepository contract,
  # including span emission with correct attributes.
  use Frame.Test.CatRepositoryConformance,
    name: "Postgres",
    factory: fn context -> Postgres.new(context.test_db.db) end,
    # Truncate between tests for full isolation.
    reset_state: fn context -> TestDb.truncate_cats(context.test_db) end,
    expected_db_system: "postgresql"

  # Postgres-specific tests — behavior that only matters with a real database.
  describe "CatRepository.Postgres — Postgres-specific" do
    setup %{test_db: test_db, test_obs: test_obs} do
      TestDb.truncate_cats(test_db)
      TestObs.reset(test_obs)
      %{repo: Postgres.new(test_db.db)}
    end

    test "concurrency: two simultaneous saves with same name — one succeeds, one fails",
         %{repo: repo} do
      name = "ConcurrentCat"
      cat1 = %Frame.Domain.Cat{id: Ecto.UUID.generate(), name: name, created_at: DateTime.utc_now()}
      cat2 = %Frame.Domain.Cat{id: Ecto.UUID.generate(), name: name, created_at: DateTime.utc_now()}

      results =
        [cat1, cat2]
        |> Enum.map(fn cat -> Task.async(fn -> CatRepository.save(repo, cat) end) end)
        |> Task.await_many()

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert [{:error, %CatAlreadyExistsError{}}] = Enum.reject(results, &(&1 == :ok))
    end
  end
end
