defmodule Trailblazer.Vortex.SettingsTest do
  use ExUnit.Case, async: true
  alias Trailblazer.Vortex.Settings

  test "only locally configured direct rooms and exact checks become authority" do
    path =
      Path.join(System.tmp_dir!(), "vortex-policy-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)
    room = Jason.encode!(["app", "caller"])

    config = %{
      "endpoint" => "/tmp/own-endpoint.json",
      "owner_peer" => "app",
      "peers" => [
        %{
          "peer" => "caller",
          "room" => room,
          "role" => "caller",
          "repos" => %{"/tmp" => ["mix test"]}
        }
      ]
    }

    File.write!(path, Jason.encode!(config))
    policy = Settings.load!(path)
    assert policy[:peers]["caller"].repos["/tmp"] == ["mix test"]

    File.write!(path, Jason.encode!(Map.put(config, "resource_mode", "dedicated")))
    dedicated = Settings.load!(path)
    assert dedicated[:resource_mode] == :dedicated
    assert {acquire, release} = dedicated[:resource]
    assert is_function(acquire, 1) and is_function(release, 1)
    File.write!(path, Jason.encode!(Map.put(config, "resource_mode", "unknown")))
    assert_raise ArgumentError, fn -> Settings.load!(path) end

    invalid =
      put_in(config, ["peers"], [
        %{"peer" => "caller", "room" => Jason.encode!(["other", "caller"]), "role" => "caller"}
      ])

    File.write!(path, Jason.encode!(invalid))

    assert_raise ArgumentError, "invalid local VORTEX configuration", fn ->
      Settings.load!(path)
    end
  end

  test "artifact commands come only from local admitted repository/check policy" do
    path =
      Path.join(System.tmp_dir!(), "artifact-policy-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)
    body = %{"prepare" => "cp source bundle", "paths" => ["bundle"], "definitions" => []}

    peer = %{
      "peer" => "caller",
      "room" => Jason.encode!(["app", "caller"]),
      "role" => "caller",
      "repos" => %{"/tmp" => ["true"]},
      "artifacts" => %{"/tmp" => %{"true" => body}}
    }

    config = %{"endpoint" => "/tmp/endpoint", "owner_peer" => "app", "peers" => [peer]}
    File.write!(path, Jason.encode!(config))
    policy = Settings.load!(path)[:peers]["caller"]
    selected = Trailblazer.Loop.Artifacts.select(policy.artifacts, "/tmp", "true")
    assert Map.delete(selected, "sha256") == body
    assert byte_size(selected["sha256"]) == 64

    for artifacts <- [
          %{"/tmp" => %{"other check" => body}},
          %{"/" => %{"true" => body}},
          %{"/tmp" => %{"true" => %{body | "paths" => ["../escape"]}}}
        ] do
      File.write!(
        path,
        Jason.encode!(%{config | "peers" => [Map.put(peer, "artifacts", artifacts)]})
      )

      assert {:error, :invalid_config} = Settings.load(path)
    end
  end
end
