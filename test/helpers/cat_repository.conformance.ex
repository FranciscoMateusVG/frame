defmodule Frame.Test.CatRepositoryConformance do
  @moduledoc """
  Shared conformance test suite for CatRepository implementations.

  Any adapter implementing `Frame.Adapters.CatRepository` must pass these
  tests. This ensures the in-memory adapter and the Postgres adapter conform
  to the same contract.

  Includes behavioral tests (save, find, delete, duplicate rejection) AND
  observability tests (every function must produce a span with the correct
  name and semantic attributes).

  Usage (the context must contain `:test_obs`):

      use Frame.Test.CatRepositoryConformance,
        name: "Memory",
        factory: fn _context -> Frame.Adapters.CatRepository.Memory.new() end,
        expected_db_system: "memory"

  Options:

    * `:factory` — `fn context -> repo end`, called before each test.
    * `:reset_state` — optional `fn context -> any end`, called before each
      test to reset state (e.g. truncate tables). Not needed for in-memory.
    * `:expected_db_system` — expected value of the `db.system` attribute.

  Pattern: future repositories (DogRepository, etc.) should follow the same
  approach — a shared conformance suite that any adapter must satisfy.
  """

  defmacro __using__(opts) do
    reset_state =
      if opts[:reset_state],
        do: quote(do: unquote(opts[:reset_state]).(context)),
        else: :ok

    quote do
      describe "CatRepository conformance — #{unquote(opts[:name])}" do
        import Frame.Test.CatRepositoryConformance, only: [make_cat: 1]

        alias Frame.Adapters.CatRepository
        alias Frame.Errors.CatAlreadyExistsError
        alias Frame.Test.Observability, as: TestObs

        setup context do
          unquote(reset_state)
          TestObs.reset(context.test_obs)
          %{repo: unquote(opts[:factory]).(context)}
        end

        @expected_db_system unquote(opts[:expected_db_system])

        # --- Behavioral tests ---

        test "saves and finds a cat by ID", %{repo: repo} do
          cat = make_cat(name: "Whiskers")
          assert :ok = CatRepository.save(repo, cat)

          found = CatRepository.find_by_id(repo, cat.id)
          assert found
          assert found.id == cat.id
          assert found.name == cat.name
        end

        test "saves and finds a cat by name", %{repo: repo} do
          cat = make_cat(name: "Luna")
          assert :ok = CatRepository.save(repo, cat)

          found = CatRepository.find_by_name(repo, "Luna")
          assert found
          assert found.id == cat.id
        end

        test "returns nil for non-existent ID", %{repo: repo} do
          assert CatRepository.find_by_id(repo, Ecto.UUID.generate()) == nil
        end

        test "returns nil for non-existent name", %{repo: repo} do
          assert CatRepository.find_by_name(repo, "Ghost") == nil
        end

        test "deletes a cat by ID", %{repo: repo} do
          cat = make_cat(name: "DeleteMe")
          assert :ok = CatRepository.save(repo, cat)

          assert CatRepository.delete_by_id(repo, cat.id) == true
          assert CatRepository.find_by_id(repo, cat.id) == nil
        end

        test "returns false when deleting a non-existent cat", %{repo: repo} do
          assert CatRepository.delete_by_id(repo, Ecto.UUID.generate()) == false
        end

        test "rejects duplicate names with CatAlreadyExistsError", %{repo: repo} do
          name = "DuplicateCat"
          assert :ok = CatRepository.save(repo, make_cat(name: name))

          assert {:error, %CatAlreadyExistsError{}} =
                   CatRepository.save(repo, make_cat(name: name))
        end

        # --- Span emission tests ---

        test "save emits a db.cats.save span with correct attributes", context do
          assert :ok = CatRepository.save(context.repo, make_cat(name: "SpanCat"))

          span = TestObs.find_span(TestObs.get_spans(context.test_obs), "db.cats.save")
          assert span
          assert span.attributes[:"db.system"] == @expected_db_system
          assert span.attributes[:"db.operation.name"] == "INSERT"
          assert span.attributes[:"db.collection.name"] == "cats"
        end

        test "findById emits a db.cats.findById span with correct attributes", context do
          CatRepository.find_by_id(context.repo, Ecto.UUID.generate())

          span = TestObs.find_span(TestObs.get_spans(context.test_obs), "db.cats.findById")
          assert span
          assert span.attributes[:"db.system"] == @expected_db_system
          assert span.attributes[:"db.operation.name"] == "SELECT"
          assert span.attributes[:"db.collection.name"] == "cats"
        end

        test "findByName emits a db.cats.findByName span with correct attributes", context do
          CatRepository.find_by_name(context.repo, "Ghost")

          span = TestObs.find_span(TestObs.get_spans(context.test_obs), "db.cats.findByName")
          assert span
          assert span.attributes[:"db.system"] == @expected_db_system
          assert span.attributes[:"db.operation.name"] == "SELECT"
          assert span.attributes[:"db.collection.name"] == "cats"
        end

        test "deleteById emits a db.cats.deleteById span with correct attributes", context do
          CatRepository.delete_by_id(context.repo, Ecto.UUID.generate())

          span = TestObs.find_span(TestObs.get_spans(context.test_obs), "db.cats.deleteById")
          assert span
          assert span.attributes[:"db.system"] == @expected_db_system
          assert span.attributes[:"db.operation.name"] == "DELETE"
          assert span.attributes[:"db.collection.name"] == "cats"
        end

        test "save records exception on span when duplicate name", context do
          name = "SpanErrorCat"
          assert :ok = CatRepository.save(context.repo, make_cat(name: name))
          TestObs.reset(context.test_obs)

          assert {:error, _} = CatRepository.save(context.repo, make_cat(name: name))

          span = TestObs.find_span(TestObs.get_spans(context.test_obs), "db.cats.save")
          assert span
          assert span.status.code == :error
          assert TestObs.exception_event?(span)
        end
      end
    end
  end

  @doc "Creates a Cat with sensible defaults."
  def make_cat(overrides) do
    struct!(
      %Frame.Domain.Cat{
        id: Ecto.UUID.generate(),
        name: "DefaultCat",
        created_at: DateTime.utc_now()
      },
      overrides
    )
  end
end
