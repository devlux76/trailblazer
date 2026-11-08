defmodule Trailblazer.Indexer.Sync do
  @moduledoc "One graph sync: lists the files it must cover, plans each path (skip, parse, mark stale or delete), and writes the store one path at a time in the order planned."

  alias Trailblazer.Graph.Resolve
  alias Trailblazer.{Files, Store}
  import Trailblazer.Indexer.Parse, only: [parse_outcomes: 2]

  @file_module_languages Trailblazer.Indexer.Parse.file_module_languages()

  @doc false
  def merge_dirty(:all, _), do: :all
  def merge_dirty(_, :all), do: :all
  def merge_dirty(a, b), do: MapSet.union(a, b)

  @doc false
  def sync_files(s, selection) do
    try do
      list =
        cond do
          selection == :all ->
            Keyword.get(s.opts, :list_files, &Files.list/1).(s.path)

          seam = s.opts[:list_files] ->
            Enum.filter(seam.(s.path), &MapSet.member?(selection, &1.path))

          true ->
            Files.entries(s.path, selection)
        end

      priority = Enum.map(list, &Map.get(&1, :mtime, 0)) |> Enum.max(fn -> 0 end)
      s = %{s | embed_priority: max(priority, s.embed_priority)}
      known = Store.files(s.id) |> Map.new(&{&1.path, &1.hash})

      # J28: the module paths only, not the whole graph, on every sync
      modules = MapSet.new(Store.module_paths(s.id))

      listed = Map.new(list, &{&1.path, &1})

      paths =
        if selection == :all, do: Enum.uniq(Map.keys(known) ++ Map.keys(listed)), else: selection

      plan = Enum.map(paths, &plan(&1, s, listed, known, modules))
      outcomes = parse_outcomes(plan, s)

      {counts, s} =
        Enum.reduce(plan, {%{parsed: 0, deleted: 0, stale: 0}, s}, &write(&1, &2, outcomes))

      # J31: every graph write above increments a count, including file-module
      # upgrades and stale recovery. A failed/interrupted sync may have written
      # files without resolving; old hot-loaded state also resolves once.
      if counts == %{parsed: 0, deleted: 0, stale: 0} and Map.get(s, :edges_current, false) and
           Store.resolution_current?(s.id) do
        {{:ok, counts}, s}
      else
        # J34 selects durable affected owners on compatible coverage, otherwise
        # rebuilding a full baseline. No filesystem/embedding scope changes.
        resolved = Resolve.next(s.id)

        case Store.replace_resolved_sources(s.id, resolved.revision, resolved) do
          :ok -> {{:ok, counts}, Map.put(s, :edges_current, true)}
          error -> {error, Map.put(s, :edges_current, false)}
        end
      end
    rescue
      e in [File.Error, RuntimeError] ->
        {{:error, {:listing_failed, Exception.message(e)}}, Map.put(s, :edges_current, false)}

      # any other exception in a sync is that sync's error, never the indexer's end (E16)
      e ->
        {{:error, {:sync_failed, Exception.message(e)}}, Map.put(s, :edges_current, false)}
    catch
      # so is an exit (a Store call that times out, a callee that exits): the
      # transient indexer would otherwise be restarted into the same exit until
      # its supervisor, and Restore with it, went down (Codex's review of a90709e)
      kind, reason when kind in [:exit, :throw] ->
        {{:error, {:sync_failed, {kind, reason}}}, Map.put(s, :edges_current, false)}
    end
  end

  defp stale(s, path, counts) do
    Store.mark_stale(s.id, path)
    {Map.update!(counts, :stale, &(&1 + 1)), %{s | stale: MapSet.put(s.stale, path)}}
  end

  defp delete(s, path, counts) do
    Store.delete_file(s.id, path)
    {Map.update!(counts, :deleted, &(&1 + 1)), %{s | stale: MapSet.delete(s.stale, path)}}
  end

  # What a path of this sync needs, decided from the listing, the indexed
  # hashes and the stale set alone: no file is read and nothing is written, so
  # the plan is the order the writes below keep.
  defp plan(path, s, listed, known, modules) do
    cond do
      Map.has_key?(listed, path) ->
        file = listed[path]

        needs_module =
          file.lang in @file_module_languages and
            not MapSet.member?(modules, path)

        if known[path] == file.hash and not MapSet.member?(s.stale, path) and
             not needs_module do
          :skip
        else
          {:parse, path, file.lang}
        end

      Map.has_key?(known, path) ->
        case File.lstat(Path.join(s.path, path)) do
          {:error, :enoent} ->
            {:delete, path}

          {:ok, %File.Stat{type: :regular, size: size}} when size == 0 or size > 400_000 ->
            {:delete, path}

          _ ->
            {:stale, path}
        end

      true ->
        :none
    end
  end

  # The store writes, one path at a time, in the order the plan was made in, so
  # the counts, the stale set and every stored row are what they were.
  defp write(:skip, acc, _outcomes), do: acc
  defp write(:none, acc, _outcomes), do: acc
  defp write({:delete, path}, {counts, s}, _outcomes), do: delete(s, path, counts)
  defp write({:stale, path}, {counts, s}, _outcomes), do: stale(s, path, counts)

  defp write({:parse, path, _lang}, {counts, s}, outcomes) do
    case Map.fetch!(outcomes, path) do
      {:ok, file} ->
        :ok = Store.replace_file(s.id, path, file)
        {Map.update!(counts, :parsed, &(&1 + 1)), %{s | stale: MapSet.delete(s.stale, path)}}

      {:error, _} ->
        stale(s, path, counts)

      {:raised, {:exit, reason}} ->
        exit(reason)

      {:raised, {:throw, reason}} ->
        throw(reason)

      {:raised, e, stack} ->
        reraise e, stack
    end
  end
end
