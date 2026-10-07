defmodule Frame.Scripts.CoverageThresholds do
  @moduledoc """
  `test_coverage` tool for `mix test --cover`: prints per-module line coverage
  and enforces explicit per-module thresholds (the equivalent of the
  reference's per-file vitest coverage thresholds).

  Configured in `mix.exs` under `test_coverage`:

    * `:ignore_modules` — modules (or regexes) excluded from the report.
    * `:thresholds` — `%{Module => [lines: pct, functions: pct]}`.

  Erlang's `:cover` measures lines and functions; it has no branch metric.
  """

  # :cover lives in OTP's :tools application, loaded on demand by `mix test --cover`.
  @compile {:no_warn_undefined, :cover}

  @doc false
  def start(compile_path, opts) do
    Mix.ensure_application!(:tools)
    _ = :cover.stop()
    {:ok, _pid} = :cover.start()

    case :cover.compile_beam_directory(String.to_charlist(compile_path)) do
      results when is_list(results) -> :ok
      {:error, reason} -> Mix.raise("Failed to cover compile #{compile_path}: #{inspect(reason)}")
    end

    fn -> report(opts) end
  end

  defp report(opts) do
    ignored = Keyword.get(opts, :ignore_modules, [])
    thresholds = Keyword.get(opts, :thresholds, %{})

    stats =
      :cover.modules()
      |> Enum.reject(&ignored?(&1, ignored))
      |> Enum.map(&module_stats/1)
      |> Enum.sort_by(& &1.module)

    print_table(stats)
    failures = Enum.flat_map(thresholds, &threshold_failures(&1, stats))

    if failures != [] do
      Enum.each(failures, &Mix.shell().error(&1))
      Mix.raise("Coverage thresholds not met")
    end
  end

  defp ignored?(module, ignored) do
    name = inspect(module)

    Enum.any?(ignored, fn
      %Regex{} = regex -> Regex.match?(regex, name)
      other -> other == module
    end)
  end

  defp module_stats(module) do
    {:ok, lines} = :cover.analyse(module, :coverage, :line)
    {:ok, functions} = :cover.analyse(module, :coverage, :function)

    lines = for {{_m, line}, counts} <- lines, line != 0, do: {line, counts}
    uncovered = for {line, {0, _}} <- lines, uniq: true, do: line
    # Compiler-generated functions (__struct__/1, __info__/1, ...) are not source code.
    functions =
      for {{_m, name, _arity}, counts} <- functions,
          not String.starts_with?(Atom.to_string(name), "__"),
          do: counts

    %{
      module: module,
      lines: percentage(Enum.map(lines, &elem(&1, 1))),
      functions: percentage(functions),
      uncovered: uncovered
    }
  end

  defp percentage([]), do: 100.0

  defp percentage(counts) do
    covered = Enum.count(counts, fn {covered, _not_covered} -> covered > 0 end)
    covered * 100 / length(counts)
  end

  defp print_table(stats) do
    Mix.shell().info("\n  Lines | Functions | Module (uncovered lines)")
    Mix.shell().info("--------|-----------|------------------------------------------")

    for %{module: module, lines: lines, functions: functions, uncovered: uncovered} <- stats do
      missing = if uncovered == [], do: "", else: " (#{Enum.join(uncovered, ",")})"
      Mix.shell().info("#{fmt(lines)} |   #{fmt(functions)} | #{inspect(module)}#{missing}")
    end

    Mix.shell().info("")
  end

  defp threshold_failures({module, limits}, stats) do
    case Enum.find(stats, &(&1.module == module)) do
      nil ->
        ["Coverage threshold module #{inspect(module)} was not measured"]

      stat ->
        for {metric, minimum} <- limits, Map.fetch!(stat, metric) < minimum do
          "ERROR: #{inspect(module)} #{metric} coverage #{fmt(Map.fetch!(stat, metric))} " <>
            "is below the threshold of #{minimum}%"
        end
    end
  end

  defp fmt(pct), do: :io_lib.format("~6.2f%", [pct]) |> IO.iodata_to_binary()
end
