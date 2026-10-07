# Example: Create a Cat using the Postgres adapter.
#
# Fully self-contained — uses Testcontainers to spin up a Postgres instance.
# No external dependencies required beyond Docker.
#
# Uses ConsoleLogger for pretty output and noop_tracer (no OTel SDK needed).
# For the full OTel tracing example, see create_cat.with_otel.exs.
#
# Usage: MIX_ENV=test mix run examples/create_cat.exs

alias Frame.Adapters.CatRepository
alias Frame.Adapters.CatRepository.Postgres
alias Frame.Observability.{ConsoleLogger, Observability, Tracer}
alias Frame.Test.TestDb

IO.puts("🐱 Frame Example: Create a Cat")
IO.puts("================================")
IO.puts("")

test_db = TestDb.create_test_database()

try do
  cat_repository = Postgres.new(test_db.db)

  deps = %{
    cat_repository: cat_repository,
    clock: &DateTime.utc_now/0,
    observability: %Observability{logger: ConsoleLogger.new(), tracer: Tracer.noop_tracer()}
  }

  # Create a cat
  {:ok, cat} = Frame.create_cat(deps, %{id: Ecto.UUID.generate(), name: "Whiskers"})
  IO.puts("✅ Created cat: #{inspect(cat)}")

  # Fetch it back
  fetched = CatRepository.find_by_id(cat_repository, cat.id)
  IO.puts("✅ Fetched cat: #{inspect(fetched)}")

  # Delete it
  deleted = CatRepository.delete_by_id(cat_repository, cat.id)
  IO.puts("✅ Deleted cat: #{inspect(deleted)}")

  # Verify deletion
  after_delete = CatRepository.find_by_id(cat_repository, cat.id)
  IO.puts("✅ After delete (should be nil): #{inspect(after_delete)}")

  IO.puts("")
  IO.puts("🎉 Example completed successfully!")
after
  TestDb.teardown(test_db)
end
