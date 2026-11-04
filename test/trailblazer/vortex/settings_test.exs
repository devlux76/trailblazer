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

  test "permission policy binds frontier peers and explicitly pins Codex sender and chat" do
    path =
      Path.join(System.tmp_dir!(), "permission-policy-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)
    room = Jason.encode!(["app", "codex-peer"])

    route = %{
      "executable" => "/home/test/bin/ping-codex",
      "cwd" => "/tmp",
      "args" => [],
      "env" => %{
        "PING_FROM" => "Trailblazer",
        "CODEX_THREAD" => "00000000-0000-4000-8000-000000000001"
      }
    }

    decider = %{
      "peer" => "codex-peer",
      "host" => "codex",
      "endpoint" => "/tmp/codex-own.json",
      "notifier" => route
    }

    permissions = %{"deciders" => %{"codex" => decider}}

    config = %{
      "endpoint" => "/tmp/app.json",
      "owner_peer" => "app",
      "peers" => [
        %{"peer" => "codex-peer", "room" => room, "role" => "frontier"}
      ]
    }

    File.write!(path, Jason.encode!(config))
    refute Keyword.has_key?(Settings.load!(path), :permissions)
    File.write!(path, Jason.encode!(Map.put(config, "permissions", permissions)))
    assert {:ok, options} = Settings.load(path)
    policy = options[:permissions]
    assert policy.timeout_ms == 14_400_000
    assert policy.deciders["codex"].peer == "codex-peer"
    assert policy.deciders["codex"].room == room
    assert policy.deciders["codex"].endpoint == "/tmp/codex-own.json"
    assert policy.deciders["codex"].notifier == route

    for bad <- [
          Map.put(permissions, "grant_all", true),
          Map.put(permissions, "timeout_ms", 0),
          %{"deciders" => %{}},
          %{"deciders" => %{"codex" => Map.put(decider, "peer", "stranger")}},
          %{"deciders" => %{"codex" => %{decider | "endpoint" => "relative"}}},
          %{"deciders" => %{"codex" => decider, "duplicate" => decider}},
          %{
            "deciders" => %{
              "codex" => put_in(decider, ["notifier", "env", "PING_FROM"], "Claude")
            }
          },
          %{"deciders" => %{"codex" => put_in(decider, ["notifier", "env", "CODEX_THREAD"], "")}}
        ] do
      File.write!(path, Jason.encode!(Map.put(config, "permissions", bad)))
      assert {:error, :invalid_config} = Settings.load(path)
    end

    caller =
      put_in(config, ["peers"], [%{"peer" => "codex-peer", "room" => room, "role" => "caller"}])

    File.write!(path, Jason.encode!(Map.put(caller, "permissions", permissions)))
    assert {:error, :invalid_config} = Settings.load(path)
  end

  test "Claude is an explicit frontier destination, never a local judgement tier" do
    peers = %{"claude-peer" => %{role: :frontier, room: "pinned-room"}}

    route = %{
      "executable" => "/home/test/bin/wake-claude",
      "cwd" => "/tmp",
      "args" => ["fixed-session"]
    }

    decider = %{
      "peer" => "claude-peer",
      "host" => "claude",
      "endpoint" => "/tmp/claude.json",
      "notifier" => route
    }

    policy = %{"timeout_ms" => 1000, "deciders" => %{"claude" => decider}}
    assert {:ok, parsed} = Trailblazer.Planner.PermissionPolicy.parse(policy, peers)
    assert parsed.timeout_ms == 1000
    assert parsed.deciders["claude"].room == "pinned-room"

    for extra <- [%{"tier" => "local"}, %{"room" => "untrusted-room"}, %{"host" => "local"}] do
      changed = %{policy | "deciders" => %{"claude" => Map.merge(decider, extra)}}

      assert {:error, :invalid_permissions} =
               Trailblazer.Planner.PermissionPolicy.parse(changed, peers)
    end
  end

  test "task-collaborator roles and malformed peer identities cannot become deciders" do
    route = %{"executable" => "/home/test/bin/wake-claude", "cwd" => "/tmp", "args" => []}

    outcomes =
      for {peer, role} <- [{"coder-peer", :collaborator}, {nil, :frontier}] do
        d = %{
          "peer" => peer,
          "host" => "claude",
          "endpoint" => "/tmp/own.json",
          "notifier" => route
        }

        Trailblazer.Planner.PermissionPolicy.parse(
          %{"deciders" => %{"reviewer" => d}},
          %{peer => %{role: role, room: "room"}}
        )
      end

    assert outcomes == [{:error, :invalid_permissions}, {:error, :invalid_permissions}]
  end
end
