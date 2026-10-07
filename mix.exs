defmodule Frame.MixProject do
  use Mix.Project

  def project do
    [
      app: :frame,
      version: "0.1.0",
      description:
        "AI-native Elixir SDK skeleton — reference implementation with hexagonal architecture",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      package: package(),
      test_paths: ["test"],
      test_coverage: [
        tool: Frame.Scripts.CoverageThresholds,
        # Same exclusions as the reference: generated types, the public entry
        # point, the exported testing helper — plus test helpers and scripts,
        # which the reference never measures (it only covers src/).
        ignore_modules: [
          Frame,
          Frame.Adapters.DbTypes.Cats,
          ~r/^Frame\.Testing\./,
          ~r/^Frame\.Test\./,
          ~r/^Mix\.Tasks\./,
          ~r/^Frame\.Scripts\./
        ],
        # Per-module thresholds (percent). :cover measures lines and functions.
        thresholds: %{
          Frame.Domain.Cat => [lines: 90, functions: 90],
          Frame.UseCases.CreateCat => [lines: 90, functions: 90]
        }
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def cli do
    [preferred_envs: [check: :test, "test.coverage": :test]]
  end

  # scripts/ holds the Mix tasks behind the gate (dev/test only, never shipped);
  # test/helpers holds shared test utilities (also used by examples/).
  defp elixirc_paths(:test), do: ["lib", "scripts", "test/helpers"]
  defp elixirc_paths(:dev), do: ["lib", "scripts"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:opentelemetry_api, "~> 1.5"},
      # OTel SDK: optional, only for Frame.Testing (consumers own their SDK setup).
      {:opentelemetry, "~> 1.7", optional: true, runtime: false},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22.4"},
      # Logs SDK (otel_log_handler) — OtelLogger tests only.
      {:opentelemetry_experimental, "~> 0.6.0", only: :test, runtime: false},
      {:testcontainers, "~> 2.4", only: [:dev, :test]},
      {:stream_data, "~> 1.4", only: [:dev, :test]},
      {:bandit, "~> 1.12", only: [:dev, :test]},
      {:plug, "~> 1.20", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [licenses: ["MIT"], links: %{}, files: ~w(lib migrations mix.exs README.md)]
  end

  defp aliases do
    [
      setup: ["deps.get", "cmd git config core.hooksPath .githooks"],
      lint: ["format --check-formatted", "credo --strict"],
      "lint.fix": ["format"],
      typecheck: ["compile --warnings-as-errors"],
      "test.coverage": ["test --cover"],
      build: ["hex.build"],
      "db.up": ["cmd docker compose -f docker/docker-compose.yml up -d"],
      "db.down": ["cmd docker compose -f docker/docker-compose.yml down"],
      "db.reset": [
        "cmd docker compose -f docker/docker-compose.yml down -v",
        "cmd docker compose -f docker/docker-compose.yml up -d --wait",
        "frame.migrate"
      ],
      "db.migrate": ["frame.migrate"],
      "db.codegen": ["frame.db_codegen"],
      # The Definition of Done. Every step must pass; the first failure aborts.
      check: [
        "lint",
        "frame.lint_structure",
        "typecheck",
        "frame.depcruise",
        "frame.check_codegen_drift",
        "test.coverage",
        "cmd env MIX_ENV=test mix run examples/create_cat.exs",
        "cmd env MIX_ENV=test mix run examples/create_cat.with_otel.exs",
        "cmd env MIX_ENV=test mix run examples/create_cat.plug.exs",
        "frame.verify_hooks"
      ]
    ]
  end
end
