defmodule Frame.MixProject do
  use Mix.Project

  def project do
    [
      app: :frame,
      version: "0.1.0",
      description:
        "Print-shop portal (BFF + server-rendered HTML) for Incluir, on the Frame skeleton",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      test_paths: ["test"],
      test_coverage: [
        tool: Frame.Scripts.CoverageThresholds,
        # Excluded: the public entry point, the exported testing helper, test
        # helpers and scripts (the reference only measures src/).
        ignore_modules: [
          Frame,
          ~r/^Frame\.Testing\./,
          ~r/^Frame\.Test\./,
          ~r/^Mix\.Tasks\./,
          ~r/^Frame\.Scripts\./
        ],
        # Per-module thresholds (percent). :cover measures lines and functions.
        thresholds: %{
          Frame.Domain.Money => [lines: 95, functions: 95],
          Frame.Domain.Competence => [lines: 95, functions: 95],
          Frame.Domain.Order => [lines: 95, functions: 95],
          Frame.Domain.Batch => [lines: 95, functions: 95],
          Frame.Domain.Document => [lines: 95, functions: 95],
          Frame.Domain.Requests => [lines: 95, functions: 95],
          Frame.Domain.Session => [lines: 95, functions: 95],
          Frame.Domain.LoginThrottle => [lines: 95, functions: 95],
          Frame.Adapters.PrintApi.Http => [lines: 85, functions: 85],
          Frame.Adapters.SessionStore.Memory => [lines: 90, functions: 90],
          Frame.Adapters.LoginLimiter.Memory => [lines: 90, functions: 90],
          Frame.Web.Edge => [lines: 90, functions: 90],
          Frame.Web.Security => [lines: 90, functions: 90],
          Frame.Web.Multipart => [lines: 90, functions: 90],
          Frame.Web.SessionController => [lines: 90, functions: 90],
          Frame.Web.PrintController => [lines: 90, functions: 90],
          Frame.Web.LoginController => [lines: 90, functions: 90],
          Frame.Web.LiveAuth => [lines: 90, functions: 90],
          Frame.Web.BatchLive => [lines: 85, functions: 85],
          Frame.Web.BatchesLive => [lines: 85, functions: 85],
          Frame.Web.InvoicesLive => [lines: 85, functions: 85],
          Frame.Config => [lines: 90, functions: 90]
        }
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {Frame.Application, []}]
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
      {:plug, "~> 1.20"},
      {:bandit, "~> 1.12"},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_html, "~> 4.2"},
      # HTTP client to the Incluir Hono API. Never follows redirects.
      {:finch, "~> 0.20"},
      # OTel SDK: optional, only for Frame.Testing (consumers own their SDK setup).
      {:opentelemetry, "~> 1.7", optional: true, runtime: false},
      # Logs SDK (otel_log_handler) — OtelLogger tests only.
      {:opentelemetry_experimental, "~> 0.6.0", only: :test, runtime: false},
      {:stream_data, "~> 1.4", only: [:dev, :test]},
      # HTML parser behind Phoenix.LiveViewTest (LiveView >= 1.1).
      {:lazy_html, "~> 0.1", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp releases do
    [
      print_portal: [
        applications: [frame: :permanent],
        include_executables_for: [:unix],
        strip_beams: true
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "cmd git config core.hooksPath .githooks"],
      lint: ["format --check-formatted", "credo --strict"],
      "lint.fix": ["format"],
      typecheck: ["compile --force --warnings-as-errors"],
      "test.coverage": ["test --cover"],
      # The Definition of Done. Every step must pass; the first failure aborts.
      check: [
        "lint",
        "frame.lint_structure",
        # Own OS process: Mix runs each task once per session, and loading the
        # project's gate tasks (above) may already have compiled the app.
        "cmd env MIX_ENV=test mix typecheck",
        "frame.depcruise",
        "test.coverage",
        "cmd env MIX_ENV=test mix run --no-start examples/portal_journey.exs",
        "cmd env MIX_ENV=test mix run --no-start examples/portal_journey.with_otel.exs",
        "frame.verify_hooks"
      ]
    ]
  end
end
