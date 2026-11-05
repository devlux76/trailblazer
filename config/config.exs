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
  config :trailblazer,
    investigate_transport: :none,
    embed_probe: :down,
    memory_record: false,
    loop_rerank: false
end

# Coding roles (operator, 2026-11-05): Nemotron Bolt codes in text edit mode on
# the CPU router (the only local model to pass the contact.ts benchmark, 4/4);
# Spark plans and reviews on its own server (operator: balance the loop; the
# planner decision call is temperature 0, thinking off, JSON-schema bounded),
# never reviewing its own work. Bolt's iGPU service emits EOS after one token.
if config_env() == :prod do
  config :trailblazer,
    code_model: "nemotron-3.5-bolt-e4b:q4",
    code_model_url: "http://127.0.0.1:8094/v1",
    code_edit_mode: :text,
    code_model_sampling: %{temperature: 0.6, top_p: 0.95, top_k: 20, thinking: false},
    review_model: "spark-x2.6-4b-q8-dspark",
    review_model_url: "http://127.0.0.1:8096/v1",
    review_model_sampling: %{thinking: false},
    planner_model: "spark-x2.6-4b-q8-dspark",
    planner_model_url: "http://127.0.0.1:8096/v1"
end
