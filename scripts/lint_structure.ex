defmodule Mix.Tasks.Frame.LintStructure do
  @shortdoc "Enforces the folder/file layout (eslint-plugin-project-structure equivalent)"
  @moduledoc """
  Structural gate on file and folder layout — the equivalent of the
  reference's `folder-structure.mjs` (eslint-plugin-project-structure).

  SCOPE: only the architectural directories — `lib/`, `test/`, `examples/`,
  `scripts/` — and only Elixir source files (`.ex`/`.exs`) in
  them. Root config files and operational folders (`.claude/`, `.githooks/`,
  `docker/`) are intentionally not modeled. `*.generated.ex` is ignored.

  WHAT THIS ENFORCES:

    * `lib/` follows the hexagonal layout (domain / use_cases / adapters /
      errors / observability / testing) with snake_case file names and the
      conventional shapes (`*_error.ex`, `<port>.ex` + `<port>/<impl>.ex`).
    * `test/` mirrors the unit / integration / helpers split with `_test.exs`.
    * `examples/` and `scripts/` follow their conventions.

  WHAT THIS DOES NOT ENFORCE: import-graph rules (`mix frame.depcruise`) or
  lint/format (`mix format` + Credo).

  To allow a new file kind, add a node to `structure/0`. To allow a one-off
  exception, add it to `@ignore_patterns`.
  """

  use Mix.Task

  @roots ["lib", "test", "examples", "scripts"]
  @ignore_patterns [~r/\.generated\.ex$/]

  @snake "[a-z][a-z0-9]*(?:_[a-z0-9]+)*"

  defp structure do
    flat_ex = [file(~r/^#{@snake}\.ex$/)]
    tests = [file(~r/^#{@snake}_test\.exs$/), file(~r/^#{@snake}\.#{@snake}_test\.exs$/)]

    [
      # ── lib/ — the architecture proper ──
      dir("lib", [
        file("frame.ex"),
        dir("frame", [
          # The composition root (OTP application) and boot configuration.
          file("application.ex"),
          file("config.ex"),
          # `use Frame.Web, :controller | :live_view | :html`.
          file("web.ex"),
          dir("domain", flat_ex),
          dir("use_cases", flat_ex),
          # <port>.ex (the behaviour) AND <port>/<impl>.ex (memory, postgres, ...)
          dir("adapters", flat_ex ++ [dir(~r/^#{@snake}$/, flat_ex)]),
          dir("errors", [file(~r/^#{@snake}_error\.ex$/)]),
          dir("observability", flat_ex),
          # The Phoenix edge: endpoint, router, plugs, components, browser
          # security; controllers and LiveViews in their own folders.
          dir(
            "web",
            flat_ex ++
              [
                dir("controllers", [file(~r/^#{@snake}_controller\.ex$/)]),
                dir("live", [file(~r/^#{@snake}_live\.ex$/)])
              ]
          ),
          dir("testing", flat_ex)
        ])
      ]),

      # ── test/ — unit / integration / shared helpers ──
      dir("test", [
        file("test_helper.exs"),
        # Simple test AND adapter-flavored test (cat_repository.memory_test.exs).
        dir("unit", tests),
        dir("integration", tests),
        # Helpers may carry one extra qualifier (cat_repository.conformance.ex).
        dir("helpers", [file(~r/^#{@snake}\.ex$/), file(~r/^#{@snake}\.#{@snake}\.ex$/)])
      ]),

      # ── examples/ — <use_case>.exs, <use_case>.with_<integration>.exs, <use_case>.<flavor>.exs ──
      dir("examples", [
        file(~r/^#{@snake}\.exs$/),
        file(~r/^#{@snake}\.with_#{@snake}\.exs$/),
        file(~r/^#{@snake}\.#{@snake}\.exs$/)
      ]),

      # ── scripts/ — the Mix tasks behind the gate ──
      dir("scripts", [file(~r/^#{@snake}\.exs?$/)])
    ]
  end

  defp file(pattern), do: {:file, pattern}
  defp dir(pattern, children), do: {:dir, pattern, children}

  @impl true
  def run(_args) do
    files =
      @roots
      |> Enum.flat_map(&Path.wildcard("#{&1}/**/*.{ex,exs}"))
      |> Enum.reject(fn path -> Enum.any?(@ignore_patterns, &Regex.match?(&1, path)) end)
      |> Enum.sort()

    errors = Enum.reject(files, &allowed?(Path.split(&1), structure()))

    if errors == [] do
      Mix.shell().info("✔ folder structure OK (#{length(files)} files checked)")
    else
      for path <- errors do
        Mix.shell().error("  error project-structure/folder-structure: #{path} is not allowed here")
      end

      Mix.shell().error("\n✘ #{length(errors)} structure violations")
      exit({:shutdown, 1})
    end
  end

  defp allowed?([name], nodes),
    do: Enum.any?(nodes, &(match?({:file, _}, &1) and name_matches?(&1, name)))

  defp allowed?([name | rest], nodes) do
    Enum.any?(nodes, fn
      {:dir, _pattern, children} = node -> name_matches?(node, name) and allowed?(rest, children)
      {:file, _pattern} -> false
    end)
  end

  defp name_matches?(node, name) do
    case elem(node, 1) do
      %Regex{} = regex -> Regex.match?(regex, name)
      literal -> literal == name
    end
  end
end
