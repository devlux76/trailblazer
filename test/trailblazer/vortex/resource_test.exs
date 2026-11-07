defmodule Trailblazer.Vortex.ResourceTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Vortex.Resource

  setup do
    lock = Path.join(System.tmp_dir!(), "resource-#{System.unique_integer([:positive])}.lock")

    {:ok, io} =
      Agent.start_link(fn -> %{offline: true, models: :exclusive, unload: :ok, others: :busy} end)

    opts = [
      name: nil,
      lock: lock,
      model: "qwen",
      offline: fn -> Agent.get(io, & &1.offline) end,
      router: fn op ->
        Agent.get_and_update(io, fn s ->
          case op do
            :models ->
              {s.models, s}

            :idle ->
              {true, s}

            :unload ->
              {s.unload, if(s.unload == :ok, do: %{s | models: :unloaded}, else: s)}

            # idle others are unloaded; busy ones stay
            :evict_idle ->
              {s.others, if(s.others == :idle, do: %{s | models: :unloaded}, else: s)}
          end
        end)
      end
    ]

    server = start_supervised!({Resource, opts})
    on_exit(fn -> File.rm(lock) end)
    %{server: server, io: io, opts: opts}
  end

  test "kernel lock excludes another holder until verified unload", c do
    assert {:ok, lease} = Resource.acquire("case-a", c.server)
    other = start_supervised!({Resource, c.opts}, id: :other)
    assert :blocked = Resource.acquire("case-b", other)
    assert :ok = Resource.release(lease, c.server)
    assert {:ok, next} = Resource.acquire("case-b", other)
    assert :ok = Resource.release(next, other)
  end

  test "active Mirai or another resident model prevents dispatch", c do
    Agent.update(c.io, &%{&1 | offline: false})
    assert :blocked = Resource.acquire("a", c.server)
    Agent.update(c.io, &%{&1 | offline: true, models: :other})
    assert :blocked = Resource.acquire("a", c.server)
  end

  test "an idle model another role left on the shared router is unloaded, then dispatch proceeds",
       c do
    Agent.update(c.io, &%{&1 | models: :other, others: :idle})
    assert {:ok, lease} = Resource.acquire("a", c.server)
    assert :ok = Resource.release(lease, c.server)
    # never while Mirai is online
    Agent.update(c.io, &%{&1 | offline: false, models: :other, others: :idle})
    assert :blocked = Resource.acquire("b", c.server)
    assert Agent.get(c.io, & &1.models) == :other
  end

  test "failed unload retains lock and stale token cannot release current ownership", c do
    assert {:ok, lease} = Resource.acquire("a", c.server)
    Agent.update(c.io, &%{&1 | unload: :error})
    assert {:error, :release_unconfirmed} = Resource.release(lease, c.server)
    assert :blocked = Resource.acquire("b", c.server)
    assert {:error, :stale_lease} = Resource.release("stale", c.server)
    Agent.update(c.io, &%{&1 | unload: :ok})
    assert :ok = Resource.release(lease, c.server)
  end

  test "malformed router models and slots fail closed without killing the lease owner", c do
    {:ok, responses} = Agent.start_link(fn -> %{"data" => [nil]} end)
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(socket)
    listener = spawn_link(fn -> serve(socket, responses) end)
    old = Application.get_env(:trailblazer, :code_model_url)
    Application.put_env(:trailblazer, :code_model_url, "http://127.0.0.1:#{port}/v1")

    on_exit(fn ->
      if old,
        do: Application.put_env(:trailblazer, :code_model_url, old),
        else: Application.delete_env(:trailblazer, :code_model_url)

      :gen_tcp.close(socket)
      Process.unlink(listener)
      Process.exit(listener, :kill)
    end)

    real = start_supervised!({Resource, Keyword.delete(c.opts, :router)}, id: :http_resource)
    assert :blocked = Resource.acquire("bad-model", real)
    assert Process.alive?(real)

    Agent.update(responses, fn _ ->
      %{
        "data" => [%{"id" => "other", "aliases" => "invalid", "status" => %{"value" => "loaded"}}]
      }
    end)

    assert :blocked = Resource.acquire("bad-aliases", real)

    Agent.update(responses, fn _ ->
      %{
        "data" => [
          %{"id" => Trailblazer.Config.get(:code_model), "status" => %{"value" => "loaded"}}
        ]
      }
    end)

    # The slots request receives an object instead of a list.
    assert :blocked = Resource.acquire("bad-slots", real)

    Agent.update(responses, fn _ ->
      %{"data" => [%{"id" => "other", "status" => %{"value" => "unloaded"}}]}
    end)

    assert {:ok, lease} = Resource.acquire("release", real)
    Agent.update(responses, fn _ -> %{"data" => [nil]} end)
    assert {:error, :release_unconfirmed} = Resource.release(lease, real)
    assert Process.alive?(real)

    Agent.update(responses, fn _ ->
      %{"data" => [%{"id" => "other", "status" => %{"value" => "unloaded"}}]}
    end)

    assert :ok = Resource.release(lease, real)
  end

  defp serve(socket, responses) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        :gen_tcp.recv(client, 0, 2000)
        body = Jason.encode!(Agent.get(responses, & &1))

        :gen_tcp.send(
          client,
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
            body
        )

        :gen_tcp.close(client)
        serve(socket, responses)

      _ ->
        :ok
    end
  end

  test "losing the kernel lock holder terminates the grant owner", c do
    assert {:ok, _} = Resource.acquire("a", c.server)
    %{held: {_, port}} = :sys.get_state(c.server)
    ref = Process.monitor(c.server)
    {_, pid} = Port.info(port, :os_pid)
    System.cmd("kill", ["-KILL", Integer.to_string(pid)])
    assert_receive {:DOWN, ^ref, :process, _, _}
  end

  test "restart recovery reacquires lock and verifies unload before releasing an old lease", c do
    assert {:ok, lease} = Resource.acquire("a", c.server)
    stop_supervised!(Resource)
    restored = start_supervised!({Resource, c.opts})
    assert :ok = Resource.release(lease, restored)
    assert {:ok, next} = Resource.acquire("b", restored)
    assert :ok = Resource.release(next, restored)
  end

  test "every router check and the unload name the lease holder's model", c do
    {:ok, seen} = Agent.start_link(fn -> [] end)
    {:ok, loaded} = Agent.start_link(fn -> true end)

    router = fn op, model ->
      Agent.update(seen, &[{op, model} | &1])

      case op do
        :models -> if(Agent.get(loaded, & &1), do: :exclusive, else: :unloaded)
        :idle -> true
        :unload -> Agent.update(loaded, fn _ -> false end)
        :evict_idle -> :busy
      end
    end

    opts = Keyword.put(c.opts, :router, router)
    server = start_supervised!({Resource, opts}, id: :model_resource)
    stop_supervised!(Resource)

    assert {:ok, lease} = Resource.acquire("planner", server, "bolt")
    assert :ok = Resource.release(lease, server, "bolt")
    assert {:unload, "bolt"} in Agent.get(seen, & &1)
    assert Enum.all?(Agent.get(seen, & &1), fn {_, model} -> model == "bolt" end)

    Agent.update(seen, fn _ -> [] end)
    Agent.update(loaded, fn _ -> true end)
    assert {:ok, lease} = Resource.acquire("bridge", server)
    assert :ok = Resource.release(lease, server)
    code_model = Trailblazer.Config.get(:code_model)
    assert {:unload, code_model} in Agent.get(seen, & &1)
    assert Enum.all?(Agent.get(seen, & &1), fn {_, model} -> model == code_model end)
  end
end
