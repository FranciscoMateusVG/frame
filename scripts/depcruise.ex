defmodule Mix.Tasks.Frame.Depcruise do
  @shortdoc "Checks the architectural dependency rules (dependency-cruiser equivalent)"
  @moduledoc """
  Architectural dependency gate — the equivalent of `.dependency-cruiser.cjs`.

  Builds the dependency graph of every module compiled from `lib/` by reading
  the compiled BEAM debug info: every module referenced anywhere in a
  module's code — remote calls, struct literals, typespecs (the equivalent of
  `tsPreCompilationDeps: true`), captures — is an edge. Internal modules are
  resolved to their source file; external modules to their OTP application.

  Rules (all severity error):

    1. `domain-no-external-imports` — `lib/frame/domain/` may only depend on
       other domain files (external libraries are allowed).
    2. `use-cases-no-concrete-adapters` — `lib/frame/use_cases/` must not
       depend on concrete adapters (`lib/frame/adapters/<port>/<impl>.ex`
       with impl postgres|memory|sqlite).
    3. `no-internal-index-imports` — nothing in `lib/` depends on
       `lib/frame.ex` (the public surface).
    4. `no-otel-sdk-in-production` — nothing in `lib/` except
       `lib/frame/testing/` depends on an OTel SDK application.
    5. `no-circular` — no dependency cycles between `lib/` files.
  """

  use Mix.Task

  @otel_sdk_apps [:opentelemetry, :opentelemetry_experimental, :opentelemetry_exporter]

  @rules [
    %{
      name: "domain-no-external-imports",
      comment: "Domain layer must not import from any other layer.",
      from: ~r{^lib/frame/domain/},
      to: {:file, ~r{^lib/}, ~r{^lib/frame/domain/}}
    },
    %{
      name: "use-cases-no-concrete-adapters",
      comment:
        "Use cases may import from domain/ and adapter interfaces, but never from concrete adapter implementations.",
      from: ~r{^lib/frame/use_cases/},
      to: {:file, ~r{^lib/frame/adapters/.*/(postgres|memory|sqlite)\.ex$}, nil}
    },
    %{
      name: "no-internal-index-imports",
      comment: "Nothing internal should import from lib/frame.ex.",
      from: ~r{^lib/frame/},
      to: {:file, ~r{^lib/frame\.ex$}, nil}
    },
    %{
      name: "no-otel-sdk-in-production",
      comment:
        "Production code (lib/) must only use the OTel API, never the SDK. Exception: lib/frame/testing/.",
      from: ~r{^lib/(?!frame/testing/)},
      to: {:app, @otel_sdk_apps}
    }
  ]

  @impl true
  def run(_args) do
    Mix.Task.run("compile")
    Enum.each(@otel_sdk_apps, &Application.load/1)

    {graph, module_count} = build_graph()
    edges = for {from, tos} <- graph, to <- tos, do: {from, to}

    violations =
      for rule <- @rules, {from, to} <- edges, violates?(rule, from, to) do
        "  error #{rule.name}: #{from} → #{describe(to)}\n    #{rule.comment}"
      end ++ cycle_violations(graph)

    if violations == [] do
      Mix.shell().info(
        "✔ no dependency violations found (#{module_count} modules, #{length(edges)} dependencies cruised)"
      )
    else
      Enum.each(violations, &Mix.shell().error(&1))
      Mix.shell().error("\n✘ #{length(violations)} dependency violations")
      exit({:shutdown, 1})
    end
  end

  # %{source_file => MapSet of {:file, path} | {:app, app, module}}
  defp build_graph do
    cwd = File.cwd!()
    {:ok, modules} = :application.get_key(:frame, :modules)
    sources = Map.new(modules, &{&1, relative_source(&1, cwd)})
    external = external_module_apps()

    lib_modules = Enum.filter(modules, &String.starts_with?(sources[&1], "lib/"))

    graph =
      Enum.reduce(lib_modules, %{}, fn module, acc ->
        from = sources[module]

        targets =
          for ref <- referenced_modules(module),
              ref != module,
              target = resolve(ref, sources, external),
              target != nil and target != {:file, from},
              into: MapSet.new(),
              do: target

        Map.update(acc, from, targets, &MapSet.union(&1, targets))
      end)

    {graph, length(lib_modules)}
  end

  defp relative_source(module, cwd) do
    module.module_info(:compile)[:source] |> List.to_string() |> Path.relative_to(cwd)
  end

  defp external_module_apps do
    for {app, _desc, _vsn} <- Application.loaded_applications(),
        app != :frame,
        {:ok, mods} = :application.get_key(app, :modules),
        mod <- mods,
        into: %{},
        do: {mod, app}
  end

  defp resolve(ref, sources, external) do
    cond do
      Map.has_key?(sources, ref) -> {:file, sources[ref]}
      Map.has_key?(external, ref) -> {:app, external[ref], ref}
      true -> nil
    end
  end

  defp referenced_modules(module) do
    beam = :code.which(module)

    {:ok, {^module, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(beam, [:abstract_code])

    forms |> collect_atoms(MapSet.new()) |> MapSet.to_list()
  end

  defp collect_atoms({:atom, _anno, atom}, acc) when is_atom(atom), do: MapSet.put(acc, atom)
  defp collect_atoms(tuple, acc) when is_tuple(tuple), do: collect_atoms(Tuple.to_list(tuple), acc)
  defp collect_atoms(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect_atoms/2)
  defp collect_atoms(_other, acc), do: acc

  defp violates?(%{from: from_re} = rule, from, to) do
    Regex.match?(from_re, from) and matches_to?(rule.to, to)
  end

  defp matches_to?({:file, path_re, path_not_re}, {:file, path}) do
    Regex.match?(path_re, path) and not (path_not_re && Regex.match?(path_not_re, path))
  end

  defp matches_to?({:app, apps}, {:app, app, _module}), do: app in apps
  defp matches_to?(_rule_to, _target), do: false

  defp describe({:file, path}), do: path
  defp describe({:app, app, module}), do: "#{inspect(module)} (#{app})"

  defp cycle_violations(graph) do
    digraph = :digraph.new()

    for {from, tos} <- graph, {:file, to} <- tos do
      :digraph.add_vertex(digraph, from)
      :digraph.add_vertex(digraph, to)
      :digraph.add_edge(digraph, from, to)
    end

    cycles = :digraph_utils.cyclic_strong_components(digraph)
    :digraph.delete(digraph)

    for component <- cycles do
      "  error no-circular: #{component |> Enum.sort() |> Enum.join(" → ")}\n    No circular dependencies anywhere."
    end
  end
end
