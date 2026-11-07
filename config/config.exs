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

# Only the production store prunes Qdrant at start (Indexer.Restore): any
# other store would judge with its own registry and drop production's.
if config_env() == :prod do
  config :trailblazer, prune_vectors_on_start: true
end

# Coding roles (2026-11-06, live and measured). Every model is named by ID on
# the one optimized router (mirai-llama-router :8094, oneAPI build), which
# assigns ports and loads/unloads models; no standalone llama servers
# (operator rule: only that router and the Vulkan embedder run).
# lucet-coder-4b-omega codes (a Spark-X2.6 code fine-tune, base Spark template)
# and answers whole files, long files by <edit> range; LFM2.5-24B-A2B QAD
# reviews, so the coder never reviews its own work; hive-conductor-1.7b plans.
# Think-prefill is off: lucet echoed the prefilled trail until its window expired.
if config_env() == :prod do
  config :trailblazer,
    code_attempts: 2,
    frontier_ping: [Path.expand("~/.local/bin/ping-claude")],
    code_model: "lucet-coder-4b-omega",
    # every model by ID on the one optimized router (mirai-llama-router)
    code_model_url: "http://127.0.0.1:8094/v1",
    code_edit_mode: :text,
    code_whole_file: true,
    code_think_prefill: false,
    # thinking off: the borrowed Spark template then tells lucet "the system is
    # invoked with `thinking_effort=high`", and lucet answered with a
    # `<tool_call>thinking_effort…` instead of code (vortex:31f3d17: 4 of 4
    # replies; replayed prompt with thinking off answered with the file)
    code_model_sampling: %{temperature: 0.6, top_p: 0.95, top_k: 20, thinking: false},
    review_model: "lfm2.5-24b-a2b:qad-review",
    review_model_url: "http://127.0.0.1:8094/v1",
    review_model_sampling: %{temperature: 0.1, top_p: 1.0, top_k: 50, thinking: true},
    # Hive conductor (LFM3-1.7B role fine-tune, served --reasoning off on the
    # shared router): 5/6 on the planner probe vs 0/6 for the 24B (2026-11-06),
    # measured without a prefill.
    planner_model: "hive-conductor-1.7b",
    planner_model_url: "http://127.0.0.1:8094/v1"
end
