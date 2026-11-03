defmodule Trailblazer.BootstrapTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Config

  @invalid [
    {"invalid JSON", "{not json"},
    {"missing keys", ~s({"private":"BOOTSTRAP_SECRET"})},
    {"bad peer policy",
     ~s({"endpoint":"/tmp/test","owner_peer":"owner","peers":[{"peer":"peer","room":"[]","role":"caller"}]})},
    {"bad resource mode",
     ~s({"endpoint":"/tmp/test","owner_peer":"owner","peers":[],"resource_mode":"unknown"})},
    {"missing explicit file", nil}
  ]

  for {label, content} <- @invalid do
    test "#{label}: the real core stays usable and coding is disabled" do
      run_probe(unquote(content), "unavailable")
    end
  end

  test "no VORTEX configuration preserves standalone coding availability" do
    run_probe(:unset, "not_configured")
  end

  test "settings stay cached after files break; an explicit reload reports the failure" do
    root = Path.join(System.tmp_dir!(), "settings-cache-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    vortex = Path.join(root, "vortex.json")
    planner = Path.join(root, "planner.json")

    saved =
      for key <- [:vortex, :planner, :runtime_settings],
          do: {key, Application.fetch_env(:trailblazer, key)}

    env =
      for name <- ["TRAILBLAZER_VORTEX_CONFIG", "TRAILBLAZER_PLANNER_CONFIG"],
          do: {name, System.get_env(name)}

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, value} -> Application.put_env(:trailblazer, key, value)
          :error -> Application.delete_env(:trailblazer, key)
        end
      end

      for {key, value} <- env do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      File.rm_rf!(root)
    end)

    Application.delete_env(:trailblazer, :vortex)
    Application.delete_env(:trailblazer, :planner)

    File.write!(
      vortex,
      Jason.encode!(%{"endpoint" => "/tmp/test", "owner_peer" => "owner", "peers" => []})
    )

    File.write!(planner, ~s({"private":"BOOTSTRAP_SECRET"}))
    System.put_env("TRAILBLAZER_VORTEX_CONFIG", vortex)
    System.put_env("TRAILBLAZER_PLANNER_CONFIG", planner)
    assert :ok = Config.load_runtime_settings()
    assert Config.get(:vortex)[:owner_peer] == "owner"
    assert Config.runtime_status(:planner).state == :unavailable
    assert Config.get(:planner) == nil
    refute inspect(Config.runtime_status(:planner)) =~ "BOOTSTRAP_SECRET"
    File.write!(vortex, "corrupt after load")
    assert Config.get(:vortex)[:owner_peer] == "owner"
    assert Config.runtime_status(:vortex).state == :ok
    assert :ok = Config.load_runtime_settings()
    assert Config.get(:vortex) == nil
    assert Config.runtime_status(:vortex).state == :unavailable
  end

  defp run_probe(content, expected) do
    root = Path.join(System.tmp_dir!(), "bootstrap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    fixture = Path.join(root, "repo")
    File.cp_r!(Path.expand("../fixtures/mini", __DIR__), fixture)
    config = Path.join(root, "vortex.json")
    if is_binary(content), do: File.write!(config, content)
    paths = Path.wildcard(Path.expand("../../_build/test/lib/*/ebin", __DIR__))
    probe = Path.expand("../support/bootstrap_probe.exs", __DIR__)
    args = ["--erl", "+S 2:2"] ++ Enum.flat_map(paths, &["-pa", &1]) ++ [probe, fixture, expected]

    {output, code} =
      System.cmd("elixir", args,
        stderr_to_stdout: true,
        env: [
          {"TRAILBLAZER_STATE_DIR", Path.join(root, "state")},
          {"TRAILBLAZER_VORTEX_CONFIG", if(content == :unset, do: nil, else: config)},
          {"TRAILBLAZER_PLANNER_CONFIG", nil}
        ]
      )

    assert code == 0, output
    assert output =~ "BOOTSTRAP_OK"
    refute output =~ "BOOTSTRAP_SECRET"
  end
end
