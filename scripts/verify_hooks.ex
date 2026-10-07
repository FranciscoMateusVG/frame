defmodule Mix.Tasks.Frame.VerifyHooks do
  @shortdoc "Verifies the git hooks exist and are readable"
  @moduledoc "Fails if a required git hook in `.githooks/` is missing or unreadable."

  use Mix.Task

  @hooks_dir ".githooks"
  @required_hooks ["pre-commit", "pre-push"]

  @impl true
  def run(_args) do
    failed =
      Enum.reject(@required_hooks, fn hook ->
        path = Path.join(@hooks_dir, hook)

        case File.read(path) do
          {:ok, _} ->
            Mix.shell().info("✅ Hook exists: #{path}")
            true

          {:error, :enoent} ->
            Mix.shell().error("❌ Missing git hook: #{path}")
            false

          {:error, _} ->
            Mix.shell().error("❌ Hook not readable: #{path}")
            false
        end
      end)

    if failed == [] do
      Mix.shell().info("\n✅ All git hooks verified.")
    else
      Mix.shell().error("\n🚨 Git hooks are misconfigured. Run: mix setup")
      exit({:shutdown, 1})
    end
  end
end
