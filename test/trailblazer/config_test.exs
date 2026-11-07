defmodule Trailblazer.ConfigTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Config

  setup do
    on_exit(fn ->
      Application.delete_env(:trailblazer, :compact_roots)
      Application.delete_env(:trailblazer, :compact_limit)
    end)
  end

  test "the planner leases the CPU model only when it shares the coding model's server" do
    on_exit(fn -> Application.delete_env(:trailblazer, :planner_model_url) end)

    # every model on the one router by default: the planner shares it, leases
    assert Config.get(:planner_model_url) == Config.get(:code_model_url)
    assert Config.get(:planner_lease)

    Application.put_env(:trailblazer, :planner_model_url, "http://127.0.0.1:9999/v1")
    refute Config.get(:planner_lease)
  end

  test "the reviewer is a different model than the coder with a 15-minute backstop" do
    assert Config.get(:review_model) == "nemotron-3.5-bolt-e4b:q4"
    # by model ID on the one router (it assigns ports), never the coder's model
    assert Config.get(:review_model_url) == "http://127.0.0.1:8094/v1"
    assert Config.get(:review_backstop_ms) == 900_000
    refute Config.get(:review_model) == Config.get(:code_model)
  end

  test "documents are full length unless the repository is under a compact root" do
    assert Config.doc_limit("/home/someone/vendor/llama.cpp") == 2400

    Application.put_env(:trailblazer, :compact_roots, ["/home/someone/vendor"])
    Application.put_env(:trailblazer, :compact_limit, 600)

    assert Config.doc_limit("/home/someone/vendor/llama.cpp") == 600
    assert Config.doc_limit("/home/someone/vendor") == 600
    assert Config.doc_limit("/home/someone/projects/trailblazer") == 2400
    # a sibling whose name only starts the same way is not under the root
    assert Config.doc_limit("/home/someone/vendored/x") == 2400
  end

  test "the roots and the limit can come from the environment" do
    System.put_env("TRAILBLAZER_COMPACT_ROOTS", "/a/vendor, /b/third_party")
    System.put_env("TRAILBLAZER_COMPACT_LIMIT", "300")

    on_exit(fn ->
      System.delete_env("TRAILBLAZER_COMPACT_ROOTS")
      System.delete_env("TRAILBLAZER_COMPACT_LIMIT")
    end)

    assert Config.doc_limit("/b/third_party/zlib") == 300
    assert Config.doc_limit("/a/projects/x") == 2400
  end
end
