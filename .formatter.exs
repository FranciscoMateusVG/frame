# Used by "mix format" — the format half of the lint gate (Biome's role in the TS reference).
[
  import_deps: [:plug],
  inputs: [
    "{mix,.formatter,.credo}.exs",
    "{lib,test,scripts}/**/*.{ex,exs}",
    "examples/*.exs"
  ],
  line_length: 100
]
