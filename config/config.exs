import Config

config :trailblazer, serve_api: config_env() != :test

# `mix test` is hermetic: its store keeps the graph's database in a temporary
# directory of this run's own, not in the real state directory and not in the
# last run's, so a run never reads a previous run's graph. The name is not just
# a counter: a counter starts at 1 again in every BEAM instance, which would
# make every run share one directory.
if config_env() == :test do
  run = System.os_time(:nanosecond)

  config :trailblazer, state_dir: Path.join(System.tmp_dir!(), "trailblazer_test_#{run}")
end

# Tests never send investigation requests over VORTEX (design §13.5), and the
# shared EmbedHealth never probes the real embedder: it stays down until a test
# says otherwise.
if config_env() == :test do
  config :trailblazer, investigate_transport: :none, embed_probe: :down
end
