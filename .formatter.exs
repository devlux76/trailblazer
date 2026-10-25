# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  # the fixture repository is data for the tests, not code of ours: it is never
  # formatted, so a fixture that is deliberately odd stays odd
  excludes: ["test/fixtures/**/*.{ex,exs}"]
]
