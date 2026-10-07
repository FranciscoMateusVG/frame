# Credo — the lint half of the lint gate (Biome's role in the TS reference).
# Default checks, run with --strict.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "scripts/", "examples/", "migrations/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true
    }
  ]
}
