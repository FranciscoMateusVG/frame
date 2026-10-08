# Used by "mix format" — the format half of the lint gate (Biome's role in the TS reference).
[
  import_deps: [:plug, :phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "{mix,.formatter,.credo}.exs",
    "{lib,test,scripts}/**/*.{ex,exs}",
    "examples/*.exs"
  ],
  line_length: 100
]
