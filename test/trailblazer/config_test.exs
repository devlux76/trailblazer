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

    # Bolt on its own iGPU server by default: no CPU lease
    refute Config.get(:planner_model_url) == Config.get(:code_model_url)
    refute Config.get(:planner_lease)

    Application.put_env(:trailblazer, :planner_model_url, Config.get(:code_model_url))
    assert Config.get(:planner_lease)
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
