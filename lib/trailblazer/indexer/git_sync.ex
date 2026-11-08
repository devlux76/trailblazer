defmodule Trailblazer.Indexer.GitSync do
  @moduledoc "What a sync takes from git (design 13.7): the paths changed since the indexed HEAD, the work tree's status paths, and the HEAD the graph will then match."

  import Trailblazer.Indexer.Sync, only: [merge_dirty: 2]

  # A change to one of these can change ignored but indexed vendored trees
  # (deps/, vendor/), which git does not report (J25).
  @lockfiles ~w(mix.lock bun.lock bun.lockb package-lock.json yarn.lock pnpm-lock.yaml
                Cargo.lock poetry.lock uv.lock go.sum Gemfile.lock composer.lock)

  # Also revisit last sync's status paths: a dirty -> clean transition is
  # absent from both the committed diff and today's status (J33).
  @doc false
  def from_git(s, selection) do
    git = Keyword.get(s.opts, :git, Trailblazer.Git)
    previous = Map.get(s, :git_paths, MapSet.new())

    with {:ok, head} <- git.head(s.path),
         {:ok, status} <- git.status(s.path),
         current = MapSet.new(status.changed ++ status.removed ++ status.untracked),
         {:ok, ignored} <-
           git.ignored(s.path, MapSet.to_list(MapSet.difference(previous, current))) do
      # J29 keeps newly ignored files out of reconciliation; pending-vector
      # cleanup owns their removal. Only absent status paths need this probe.
      previous = MapSet.difference(previous, MapSet.new(ignored))

      selection =
        case committed(git, s, head) do
          {:ok, committed} ->
            paths = committed ++ MapSet.to_list(MapSet.union(previous, current))

            if Enum.any?(paths, &(Path.basename(&1) in @lockfiles)),
              do: :all,
              else: merge_dirty(selection, MapSet.new(paths))

          {:all, _} ->
            :all
        end

      {selection, oid(head), current}
    else
      # Retain prior paths on a failed git probe so the next attempt can retry.
      {:error, :not_a_work_tree} -> {:all, nil, previous}
      {:error, _} -> {:all, s.head, previous}
    end
  end

  defp committed(_git, _s, :unborn), do: {:ok, []}
  defp committed(_git, %{head: nil}, head), do: {:all, head}
  defp committed(_git, %{head: same}, same), do: {:ok, []}

  defp committed(git, s, head) do
    case git.changed(s.path, s.head) do
      {:ok, %{changed: changed, removed: removed}} -> {:ok, changed ++ removed}
      {:error, _} -> {:all, head}
    end
  end

  defp oid(:unborn), do: nil
  defp oid(head), do: head
end
