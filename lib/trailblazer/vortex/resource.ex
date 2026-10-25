defmodule Trailblazer.Vortex.Resource do
  @moduledoc "Exclusive local inference while Mirai is deliberately offline. Release requires verified router unload."
  use GenServer
  alias Trailblazer.{Backstop, Config}

  def start_link(opts),
    do:
      GenServer.start_link(
        __MODULE__,
        opts,
        if(opts[:name] == nil and Keyword.has_key?(opts, :name),
          do: [],
          else: [name: opts[:name] || __MODULE__]
        )
      )

  # `model` is the router model the holder runs (default `:code_model`): the
  # idle check and the verified unload are about that model, never another.
  def acquire(id, server \\ __MODULE__, model \\ nil),
    do: GenServer.call(server, {:acquire, id, model || Config.get(:code_model)}, :infinity)

  def release(lease, server \\ __MODULE__, model \\ nil),
    do: GenServer.call(server, {:release, lease, model || Config.get(:code_model)}, :infinity)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       lock: opts[:lock] || Path.expand("~/.local/state/local-ai/heavy.lock"),
       offline: opts[:offline] || (&offline?/0),
       router: opts[:router] || (&router/2),
       held: nil
     }}
  end

  @impl true
  def handle_call({:acquire, id, model}, _, %{held: nil} = s) do
    case take_lock(s) do
      {:ok, port} ->
        if safe?(s) and route(s, :models, model) in [:exclusive, :unloaded] and
             route(s, :idle, model) == true do
          lease = id
          {:reply, {:ok, lease}, %{s | held: {lease, port}}}
        else
          close(port)
          {:reply, :blocked, s}
        end

      _ ->
        {:reply, :blocked, s}
    end
  end

  def handle_call({:acquire, _, _}, _, s), do: {:reply, :blocked, s}

  def handle_call({:release, lease, model}, from, %{held: {lease, nil}} = s),
    do: handle_call({:release, lease, model}, from, %{s | held: nil})

  def handle_call({:release, lease, model}, from, %{held: nil} = s) do
    # A durable bridge hold survives this process. Reclaim the kernel lock
    # before attempting cleanup; never unload a newer owner's model.
    case take_lock(s) do
      {:ok, port} -> handle_call({:release, lease, model}, from, %{s | held: {lease, port}})
      _ -> {:reply, {:error, :release_unconfirmed}, s}
    end
  end

  def handle_call({:release, lease, model}, _, %{held: {lease, port}} = s) do
    result =
      if safe?(s) do
        case route(s, :models, model) do
          :unloaded ->
            :ok

          :exclusive ->
            if route(s, :unload, model) == :ok and route(s, :models, model) == :unloaded,
              do: :ok,
              else: :error

          _ ->
            :error
        end
      else
        :error
      end

    if result == :ok do
      close(port)
      {:reply, :ok, %{s | held: nil}}
    else
      {:reply, {:error, :release_unconfirmed}, s}
    end
  end

  def handle_call({:release, _, _}, _, s), do: {:reply, {:error, :stale_lease}, s}

  # A dead lock holder invalidates the grant. Keep the logical hold fenced;
  # release can only succeed after a fresh lock and verified cleanup.
  @impl true
  def handle_info({port, {:exit_status, _}}, %{held: {lease, port}} = s),
    do: {:stop, {:lock_lost, lease}, %{s | held: nil}}

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_, %{held: {_, port}}), do: close(port)
  def terminate(_, _), do: :ok

  defp safe?(s), do: s.offline.() == true

  # An injected router may ignore the model (arity 1).
  defp route(%{router: router}, op, model) when is_function(router, 2), do: router.(op, model)
  defp route(%{router: router}, op, _), do: router.(op)

  defp take_lock(s) do
    File.mkdir_p!(Path.dirname(s.lock))
    # --no-fork leaves a single cat holding the flock. Closing the Port
    # ends cat; there are no shell/grandchild lock owners to outlive us.
    port =
      Port.open(
        {:spawn_executable, System.find_executable("flock")},
        [
          :binary,
          :exit_status,
          :use_stdio,
          args: ["--nonblock", "--no-fork", s.lock, System.find_executable("cat")]
        ]
      )

    Port.command(port, "locked\n")

    receive do
      {^port, {:data, "locked\n"}} -> {:ok, port}
      {^port, {:exit_status, _}} -> :blocked
    end
  rescue
    _ -> :blocked
  end

  defp close(nil), do: :ok

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp offline? do
    guarded(fn ->
      case System.cmd(
             "/usr/bin/systemctl",
             ["show", "mirai-agent", "--property=ActiveState", "--value"],
             stderr_to_stdout: true
           ) do
        {"inactive\n", 0} -> true
        _ -> false
      end
    end) == true
  end

  defp guarded(fun) do
    case Backstop.guard(
           :resource,
           "dedicated",
           {:ms, Config.get(:backstop_store_ms)},
           fn -> %{} end,
           fun
         ) do
      {:ok, result} -> result
      _ -> :error
    end
  end

  defp router(op, model) do
    do_router(op, model)
  rescue
    _ -> :error
  end

  defp do_router(op, model) do
    base = String.trim_trailing(Config.get(:code_model_url), "/v1")

    case op do
      :models ->
        with {:ok, %{"data" => models}} when is_list(models) <- http(:get, base <> "/models"),
             true <- models != [] do
          resident = Enum.reject(models, &(get_in(&1, ["status", "value"]) == "unloaded"))

          cond do
            resident == [] ->
              :unloaded

            length(resident) == 1 and own?(hd(resident), model) and
                get_in(hd(resident), ["status", "value"]) == "loaded" ->
              :exclusive

            true ->
              :other
          end
        else
          _ -> :error
        end

      :idle ->
        case router(:models, model) do
          :unloaded ->
            true

          :exclusive ->
            case http(:get, base <> "/slots?model=" <> URI.encode_www_form(model)) do
              {:ok, slots} when is_list(slots) and slots != [] ->
                Enum.all?(slots, &(Map.get(&1, "is_processing") == false))

              _ ->
                false
            end

          _ ->
            false
        end

      :unload ->
        case http(:post, base <> "/models/unload", %{model: model}) do
          {:ok, %{"success" => true}} -> :ok
          _ -> :error
        end
    end
  end

  defp own?(entry, model), do: entry["id"] == model or model in (entry["aliases"] || [])

  defp http(method, url, body \\ nil) do
    opts = [
      method: method,
      url: url,
      retry: false,
      receive_timeout: :infinity,
      connect_options: [timeout: :infinity]
    ]

    opts = if body, do: Keyword.put(opts, :json, body), else: opts

    case guarded(fn -> Req.request(opts) end) do
      {:ok, %{status: 200, body: value}} -> {:ok, value}
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
