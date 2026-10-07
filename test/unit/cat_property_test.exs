defmodule Frame.Unit.CatPropertyTest do
  # async: false — the adapter's spans go to the global SDK when one is running.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Frame.Adapters.CatRepository
  alias Frame.Adapters.CatRepository.Memory
  alias Frame.Domain.Cat
  alias Frame.Observability.NoopLogger
  alias Frame.Observability.Observability
  alias Frame.Observability.Tracer
  alias Frame.UseCases.CreateCat

  @silent_observability %Observability{logger: NoopLogger.new(), tracer: Tracer.noop_tracer()}

  # Arbitrary Unicode strings; length bounds below are in JS terms (UTF-16
  # code units after JS-style trim), matching the reference's fast-check filters.
  defp trimmed_length(s), do: s |> Cat.trim_name() |> Cat.name_length()

  describe "Cat property-based tests" do
    property "round-trip: creating a cat then fetching it returns the same cat for any valid input" do
      check all(
              name <- string(:printable, min_length: 1, max_length: 100),
              trimmed_length(name) in 1..100,
              max_runs: 50
            ) do
        cat_repository = Memory.new()
        id = Ecto.UUID.generate()

        {:ok, created} =
          CreateCat.create_cat(
            %{
              cat_repository: cat_repository,
              clock: &DateTime.utc_now/0,
              observability: @silent_observability
            },
            %{id: id, name: name}
          )

        fetched = CatRepository.find_by_id(cat_repository, id)

        assert fetched
        assert fetched.id == created.id
        assert fetched.name == created.name
        assert fetched.created_at == created.created_at
      end
    end

    property "validation invariant: any string whose trimmed length exceeds 100 chars is rejected" do
      check all(
              long_name <- string(:printable, min_length: 101, max_length: 500),
              trimmed_length(long_name) > 100,
              max_runs: 100
            ) do
        assert {:error, _} = Cat.parse_cat_name(long_name)
      end
    end

    property "validation invariant: any non-empty trimmed string within 100 chars is accepted" do
      check all(
              name <- string(:printable, min_length: 1, max_length: 100),
              trimmed_length(name) in 1..100,
              max_runs: 100
            ) do
        assert {:ok, _} = Cat.parse_cat_name(name)
      end
    end
  end
end
