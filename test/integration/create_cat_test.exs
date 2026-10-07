defmodule Frame.Integration.CreateCatTest do
  @moduledoc """
  Integration tests for the create_cat use case.

  These are the primary behavioral spec for create_cat. They run against a
  real Postgres database via Testcontainers. Named as specs — what the use
  case does, not how it's implemented.

  Test isolation: each test truncates the cats table. Testcontainers provides
  a fresh DB per module. Any test can run independently in any order.

  Also covers span emission: parent-child relationships and error-path span
  recording.
  """
  use ExUnit.Case, async: false

  alias Frame.Adapters.CatRepository
  alias Frame.Adapters.CatRepository.Postgres
  alias Frame.Errors.CatAlreadyExistsError
  alias Frame.Errors.InvalidCatNameError
  alias Frame.Test.Observability, as: TestObs
  alias Frame.Test.TestDb
  alias Frame.UseCases.CreateCat

  @moduletag timeout: 120_000

  # Fixed clock for deterministic timestamps in tests.
  @fixed_date ~U[2026-01-15 12:00:00.000000Z]

  setup_all do
    test_obs = TestObs.create_test_observability()
    test_db = TestDb.create_test_database()

    on_exit(fn ->
      TestDb.teardown(test_db)
      TestObs.shutdown(test_obs)
    end)

    %{test_db: test_db, test_obs: test_obs}
  end

  setup %{test_db: test_db, test_obs: test_obs} do
    # Truncate between tests for full isolation.
    TestDb.truncate_cats(test_db)
    TestObs.reset(test_obs)

    # Shared deps builder — DRY across all tests.
    deps = %{
      cat_repository: Postgres.new(test_db.db),
      clock: fn -> @fixed_date end,
      observability: test_obs.observability
    }

    %{deps: deps}
  end

  defp create_cat(deps, name, id \\ Ecto.UUID.generate()),
    do: CreateCat.create_cat(deps, %{id: id, name: name})

  describe "create_cat" do
    # --- Happy path ---

    test "creates a cat with the given name", %{deps: deps} do
      id = Ecto.UUID.generate()
      assert {:ok, cat} = create_cat(deps, "Whiskers", id)

      assert cat.id == id
      assert cat.name == "Whiskers"
      assert %DateTime{} = cat.created_at
    end

    test "uses the injected clock for created_at", %{deps: deps} do
      assert {:ok, cat} = create_cat(deps, "ClockCat")
      assert cat.created_at == @fixed_date
    end

    test "persists the cat so it can be found by ID", %{deps: deps} do
      id = Ecto.UUID.generate()
      assert {:ok, _} = create_cat(deps, "Luna", id)

      found = CatRepository.find_by_id(deps.cat_repository, id)
      assert found
      assert found.name == "Luna"
    end

    test "persists the cat so it can be found by name", %{deps: deps} do
      assert {:ok, _} = create_cat(deps, "Mittens")

      found = CatRepository.find_by_name(deps.cat_repository, "Mittens")
      assert found
      assert found.name == "Mittens"
    end

    test "trims whitespace from the cat name", %{deps: deps} do
      assert {:ok, cat} = create_cat(deps, "  Whiskers  ")
      assert cat.name == "Whiskers"
    end

    test "accepts a name at exactly 100 characters", %{deps: deps} do
      name = String.duplicate("a", 100)
      assert {:ok, cat} = create_cat(deps, name)
      assert cat.name == name
    end

    # --- Validation errors ---

    test "rejects an empty name with InvalidCatNameError", %{deps: deps} do
      assert {:error, %InvalidCatNameError{}} = create_cat(deps, "")
    end

    test "rejects a name exceeding 100 characters with InvalidCatNameError", %{deps: deps} do
      assert {:error, %InvalidCatNameError{}} = create_cat(deps, String.duplicate("a", 101))
    end

    test "rejects an invalid UUID with InvalidCatNameError", %{deps: deps} do
      assert {:error, %InvalidCatNameError{}} = create_cat(deps, "Valid Name", "not-a-uuid")
    end

    test "rejects a whitespace-only name with InvalidCatNameError", %{deps: deps} do
      assert {:error, %InvalidCatNameError{}} = create_cat(deps, "   ")
    end

    # --- Duplicate handling ---

    test "rejects a duplicate name with CatAlreadyExistsError", %{deps: deps} do
      assert {:ok, _} = create_cat(deps, "OnlyOne")
      assert {:error, %CatAlreadyExistsError{}} = create_cat(deps, "OnlyOne")
    end

    test "allows creating cats with different names", %{deps: deps} do
      assert {:ok, _} = create_cat(deps, "Cat A")
      assert {:ok, cat_b} = create_cat(deps, "Cat B")
      assert cat_b.name == "Cat B"
    end

    # --- Idempotency (caller-provided IDs) ---

    test "rejects retrying with the same name (idempotency is name-based)", %{deps: deps} do
      assert {:ok, _} = create_cat(deps, "Persistent")

      # Retry with a different ID but the same name — should fail
      assert {:error, %CatAlreadyExistsError{}} = create_cat(deps, "Persistent")
    end

    # --- Span emission ---

    test "emits a createCat parent span containing a child db.cats.save span", context do
      assert {:ok, _} = create_cat(context.deps, "SpanCat")

      spans = TestObs.get_spans(context.test_obs)
      create_cat_span = TestObs.find_span(spans, "createCat")
      save_span = TestObs.find_span(spans, "db.cats.save")

      assert create_cat_span
      assert save_span

      # Verify parent-child relationship
      assert save_span.parent_span_id == create_cat_span.span_id

      # Verify they share the same trace
      assert save_span.trace_id == create_cat_span.trace_id

      # Verify createCat span attributes
      assert create_cat_span.attributes[:"cat.name.length"] == 7
    end

    test "records exception on createCat span when validation fails", context do
      assert {:error, _} = create_cat(context.deps, "")

      create_cat_span = TestObs.find_span(TestObs.get_spans(context.test_obs), "createCat")

      assert create_cat_span
      assert create_cat_span.status.code == :error
      assert TestObs.exception_event?(create_cat_span)
    end

    test "records exception on createCat span when duplicate name", context do
      assert {:ok, _} = create_cat(context.deps, "DupSpan")
      TestObs.reset(context.test_obs)

      assert {:error, _} = create_cat(context.deps, "DupSpan")

      spans = TestObs.get_spans(context.test_obs)
      create_cat_span = TestObs.find_span(spans, "createCat")
      save_span = TestObs.find_span(spans, "db.cats.save")

      # Both spans should record the error
      assert create_cat_span.status.code == :error
      assert save_span.status.code == :error

      # Both should have exception events
      assert TestObs.exception_event?(create_cat_span)
      assert TestObs.exception_event?(save_span)
    end
  end
end
