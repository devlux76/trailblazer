defmodule Trailblazer.Parse.TreeSitter.Worker do
  @moduledoc """
  One parser of the pool: a process that owns one tree-sitter Port and serves
  one file at a time for `Trailblazer.Parse.TreeSitter`.

  The Port is opened on first use and again after it has been found gone, so a
  parser that dies costs its own file and not the pool (J14). Waiting on it is
  waiting for one of three messages: the Port's reply, the Port's death, and
  the parse's one backstop (design §13.2). Only the backstop gives up, and it
  gives up that one file: the Port is closed, its OS process ends, and the next
  file opens a new one.

  Progress is published on `:parse`, so a test and an operator can see which
  parser is chewing which file without asking it.
  """
  use GenServer

  alias Trailblazer.{Backstop, Config, Events}
  alias Trailblazer.Parse.TreeSitter

  @port_options [:binary, :exit_status, :use_stdio, {:packet, 4}]

  @doc false
  def start_link(pool, id), do: GenServer.start_link(__MODULE__, {pool, id})

  @impl GenServer
  def init({pool, id}) do
    # The Port is linked: without this the worker would go down with it.
    Process.flag(:trap_exit, true)
    {:ok, %{id: id, pool: pool, port: nil}}
  end

  @impl GenServer
  def handle_cast({:parse, token, path, lang, source}, state) do
    {result, state} = parse(state, path, lang, source)
    Events.publish(:parse, {:ended, path, state.id, outcome(result)})
    send(state.pool, {:parsed, self(), token, result})
    {:noreply, state}
  end

  # A Port that died while nothing was waiting on it is let go, so the next
  # file opens a new one and is not the one told the parser is gone.
  @impl GenServer
  def handle_info({port, {:exit_status, _status}}, %{port: port} = state),
    do: {:noreply, report(%{state | port: nil})}

  def handle_info({:EXIT, port, _reason}, %{port: port} = state),
    do: {:noreply, report(%{state | port: nil})}

  # An old Port's last words change nothing here, but the pool still gets told
  # which parser this worker has now.
  def handle_info(_message, state), do: {:noreply, report(state)}

  ## Parsing one file

  defp parse(%{port: nil} = state, path, lang, source) do
    case open_port() do
      {:ok, port} -> ask(report(%{state | port: port}), path, lang, source)
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp parse(state, path, lang, source), do: ask(state, path, lang, source)

  defp ask(state, path, lang, source) do
    # One backstop per parse (design §13.2), armed by the process that waits,
    # and never a second way of giving up.
    backstop =
      Backstop.arm(:parse, path, {:ms, Config.get(:backstop_parse_ms)}, fn ->
        %{path: path, lang: lang, bytes: byte_size(source)}
      end)

    request = %{"lang" => Atom.to_string(lang), "path" => path, "source" => source}

    case send_request(state.port, request) do
      :ok ->
        Events.publish(:parse, {:started, path, state.id, os_pid(state.port)})
        await(state, backstop, path, lang, source)

      :parser_gone ->
        {crashed(backstop), close(state)}
    end
  end

  defp await(state, backstop, path, lang, source) do
    port = state.port

    receive do
      {^port, {:data, data}} ->
        {answered(backstop, data, path, lang, source), state}

      # the Port died while this file was waiting on it
      {:EXIT, ^port, _reason} ->
        {crashed(backstop), report(%{state | port: nil})}

      {^port, {:exit_status, _status}} ->
        {crashed(backstop), report(%{state | port: nil})}

      # the one way a parse is given up on: the Port goes, and the next file
      # opens a new one
      {:backstop, ^backstop, _id} ->
        {{:error, :timeout}, close(state)}
    end
  end

  # J5: the Port answered; if its backstop fired in the same moment, the
  # backstop's outcome stands, as in `Trailblazer.Loop.Check`.
  defp answered(backstop, data, path, lang, source) do
    case Backstop.disarm(backstop) do
      :ok -> TreeSitter.build(data, path, lang, source)
      :fired -> {:error, :timeout}
    end
  end

  # J5 again: the Port died. Its backstop is disarmed either way, and if it had
  # fired, that outcome stands.
  defp crashed(backstop) do
    case Backstop.disarm(backstop) do
      :ok -> {:error, :parser_crashed}
      :fired -> {:error, :timeout}
    end
  end

  ## The Port

  defp open_port do
    with {:ok, path} <- binary() do
      {:ok, Port.open({:spawn_executable, path}, @port_options)}
    end
  rescue
    error -> {:error, error}
  end

  # A Port that has died refuses the request rather than dropping it.
  defp send_request(port, request) do
    Port.command(port, Jason.encode!(request))
    :ok
  rescue
    ArgumentError -> :parser_gone
  end

  defp close(state) do
    if state.port && Port.info(state.port), do: Port.close(state.port)
    report(%{state | port: nil})
  end

  # The pool answers `os_pids/0` from what its workers last said.
  defp report(state) do
    send(state.pool, {:worker_port, self(), os_pid(state.port)})
    state
  end

  defp os_pid(nil), do: nil

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _other -> nil
    end
  end

  defp binary do
    case :code.priv_dir(:trailblazer) do
      {:error, _reason} ->
        {:error, :parser_missing}

      dir ->
        path = Path.join(dir, "ts_port")
        if File.regular?(path), do: {:ok, path}, else: {:error, :parser_missing}
    end
  end

  defp outcome({:ok, _parsed}), do: :ok
  defp outcome({:error, reason}), do: {:error, reason}
end
