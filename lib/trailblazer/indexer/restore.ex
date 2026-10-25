defmodule Trailblazer.Indexer.Restore do
  @moduledoc """
  Watches again, when the indexers start, every repository a watch once
  succeeded on (E11 in the register), so a restarted service answers without
  anyone watching again.

  A repository whose directory is gone is skipped and logged; its registration
  and its graph stay as they were. It runs after the indexers' registry and
  supervisor, as the last child of `Trailblazer.Indexer.Supervisor`, and is
  started again with them. `:restore_watch_opts` in the application
  environment is passed to each watch (tests use it for fakes).
  """

  use GenServer
  require Logger

  alias Trailblazer.{Indexer, Store}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts), do: {:ok, %{restored: [], skipped: []}, {:continue, :restore}}

  @impl GenServer
  def handle_continue(:restore, state) do
    # J27: each repository waits for its first git change or request
    # (`Indexer` `:defer`) before it reconciles or embeds.
    opts =
      Keyword.put_new(Application.get_env(:trailblazer, :restore_watch_opts, []), :defer, true)

    state =
      Enum.reduce(Store.watched_repos(), state, fn %{path: path}, state ->
        restore(path, opts, state)
      end)

    {:noreply, state}
  end

  # One repository whose watch crashes or exits is skipped; the others are
  # still restored (E16: a parser crash in mirai-agent once took this process,
  # and with it every indexer, down in a restart loop).
  defp watch(path, opts) do
    Indexer.watch(path, opts)
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exited, reason}}
  end

  defp restore(path, opts, state) do
    if File.dir?(path) do
      case watch(path, opts) do
        {:ok, _pid} ->
          %{state | restored: [path | state.restored]}

        error ->
          Logger.warning("trailblazer: could not watch #{path} again: #{inspect(error)}")
          %{state | skipped: [path | state.skipped]}
      end
    else
      Logger.warning("trailblazer: #{path} is gone; not watched again (its graph is kept)")
      %{state | skipped: [path | state.skipped]}
    end
  end
end
