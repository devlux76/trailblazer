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

  Then it prunes Qdrant (operator, 2026-11-06): every `trailblazer_`
  collection that belongs to no registered repository (gone directories
  included, as their graphs are kept), the history corpus or memory is
  dropped. Only the production release does this (`:prune_vectors_on_start`,
  set for `:prod` in config): any other store would prune with its own
  registry and drop production collections.
  """

  use GenServer
  require Logger

  alias Trailblazer.{History, Indexer, Memory, Store, Vectors}

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

    {:noreply, state, {:continue, :prune}}
  end

  def handle_continue(:prune, state) do
    # Only the production store, in its default state directory: a release
    # started with another TRAILBLAZER_STATE_DIR would judge with its own
    # registry, and every production collection would look abandoned.
    prod_store? =
      Path.expand(Trailblazer.Config.get(:state_dir)) ==
        Path.join(System.user_home!(), ".local/share/trailblazer")

    if Application.get_env(:trailblazer, :prune_vectors_on_start, false) and prod_store? do
      # Running indexers too: a repository watched during boot has its
      # collection before it is recorded as watched.
      running = Registry.select(Trailblazer.Indexer.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

      keep =
        Enum.map(Store.watched_repos(), & &1.path) ++
          running ++ [History.root(), Memory.root()]

      case Vectors.prune(keep) do
        {:ok, %{dropped: n} = counts} when n > 0 ->
          Logger.info("trailblazer: pruned Qdrant: #{inspect(counts)}")

        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("trailblazer: could not prune Qdrant: #{inspect(reason)}")
      end
    end

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
