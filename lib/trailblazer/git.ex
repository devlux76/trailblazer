defmodule Trailblazer.Git do
  @moduledoc """
  What git knows about a work tree, read without disturbing it (design §13.7).

  Every call runs with `GIT_OPTIONAL_LOCKS=0`, so status never takes
  `index.lock` and writes nothing under `.git` (J21). A repository's own
  config cannot make these calls run a program: fsmonitor hooks and external
  diff drivers are switched off. Paths are relative to the work tree's root
  and are binaries as git gives them (`-z`, no quoting). `repo` is the work
  tree's root.
  """

  @env [{"GIT_OPTIONAL_LOCKS", "0"}, {"LC_ALL", "C"}, {"GIT_TERMINAL_PROMPT", "0"}]
  @safe [
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "status.relativePaths=false"
  ]

  @doc "HEAD's commit id, `:unborn` before the first commit, or `:not_a_work_tree`."
  def head(repo) do
    with :ok <- work_tree(repo) do
      case run(repo, ["rev-parse", "--verify", "-q", "HEAD^{commit}"]) do
        {:ok, oid} -> {:ok, String.trim_trailing(oid, "\n")}
        {:error, {1, _}} -> {:ok, :unborn}
        error -> error
      end
    end
  end

  @doc """
  Files that commits changed between `since` and HEAD: `changed` (added or
  modified) and `removed`. A rename is the old path removed and the new one
  changed. `{:error, :unknown_commit}` when `since` is gone (rebased away and
  collected, J24), `{:error, :unborn}` when HEAD has no commit.
  """
  def changed(repo, since) do
    with :ok <- work_tree(repo),
         {:ok, head} when is_binary(head) <- head(repo) |> unborn(),
         :ok <- commit?(repo, since),
         {:ok, out} <-
           run(repo, [
             "diff",
             "--name-status",
             "-z",
             "--no-renames",
             "--no-ext-diff",
             "--no-textconv",
             "--ignore-submodules=all",
             since,
             head,
             "--"
           ]) do
      {:ok, name_status(String.split(out, <<0>>, trim: true), %{changed: [], removed: []})}
    end
  end

  @doc """
  The work tree against HEAD: `changed` (modified, staged, unmerged),
  `removed` (absent from the work tree) and `untracked` (not ignored).
  Submodules are their own repositories and are left out.
  """
  def status(repo) do
    with :ok <- work_tree(repo),
         {:ok, out} <-
           run(repo, [
             "status",
             "--porcelain=v2",
             "-z",
             "--untracked-files=all",
             "--no-renames",
             "--ignore-submodules=all"
           ]) do
      {:ok,
       porcelain(String.split(out, <<0>>, trim: true), %{changed: [], removed: [], untracked: []})}
    end
  end

  @doc "Every file git would track: committed or untracked and not ignored (J24's full compare)."
  def files(repo) do
    with :ok <- work_tree(repo),
         {:ok, out} <-
           run(repo, [
             "ls-files",
             "-z",
             "--cached",
             "--others",
             "--exclude-standard",
             "--deduplicate"
           ]) do
      {:ok, String.split(out, <<0>>, trim: true)}
    end
  end

  @doc """
  Which of `paths` git ignores (`.gitignore`, `.git/info/exclude`, the global
  excludes), in the order given. Git never reports a change to an ignored
  file, so this is how the indexer learns that one it indexed went quiet (J29).
  """
  def ignored(_repo, []), do: {:ok, []}

  def ignored(repo, paths) do
    with :ok <- work_tree(repo) do
      # Exit 1 is git's "none of them"; `--` keeps a path from reading as an
      # option. `-z` needs --stdin, which System.cmd cannot feed, so the answer
      # is one path per line.
      case run(repo, ["check-ignore", "--" | paths]) do
        {:ok, out} -> {:ok, String.split(out, "\n", trim: true)}
        {:error, {1, _}} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "The git directory to watch: a linked worktree's own, never the shared one."
  def git_dir(repo) do
    with :ok <- work_tree(repo),
         {:ok, dir} <- run(repo, ["rev-parse", "--path-format=absolute", "--git-dir"]) do
      {:ok, String.trim_trailing(dir, "\n")}
    end
  end

  # --name-status -z: a status letter, then the path, each NUL-terminated.
  defp name_status([status, path | rest], acc) do
    key = if String.starts_with?(status, "D"), do: :removed, else: :changed
    name_status(rest, Map.update!(acc, key, &[path | &1]))
  end

  defp name_status(_, acc), do: Map.new(acc, fn {k, v} -> {k, Enum.reverse(v)} end)

  # Porcelain v2 -z. "1 XY sub mH mI mW hH hI path"; "2 ... Xscore path" then
  # the original path as its own record; "u XY sub m1 m2 m3 mW h1 h2 h3 path";
  # "? path". A file is removed when the work tree no longer has it.
  defp porcelain(["1 " <> _ = record | rest], acc) do
    [_, xy | fields] = String.split(record, " ", parts: 9)
    porcelain(rest, put(acc, entry(xy), List.last(fields)))
  end

  defp porcelain(["2 " <> _ = record, original | rest], acc) do
    [_, xy | fields] = String.split(record, " ", parts: 10)
    porcelain(rest, acc |> put(entry(xy), List.last(fields)) |> put(:removed, original))
  end

  defp porcelain(["u " <> record | rest], acc) do
    porcelain(rest, put(acc, :changed, record |> String.split(" ", parts: 10) |> List.last()))
  end

  defp porcelain(["? " <> path | rest], acc), do: porcelain(rest, put(acc, :untracked, path))
  defp porcelain([_ | rest], acc), do: porcelain(rest, acc)
  defp porcelain([], acc), do: Map.new(acc, fn {k, v} -> {k, Enum.reverse(v)} end)

  defp entry(<<_x, ?D>>), do: :removed
  defp entry(<<?D, ?.>>), do: :removed
  defp entry(_), do: :changed

  defp put(acc, key, path), do: Map.update!(acc, key, &[path | &1])

  defp unborn({:ok, :unborn}), do: {:error, :unborn}
  defp unborn(other), do: other

  defp commit?(repo, oid) do
    if is_binary(oid) and oid != "" and not String.starts_with?(oid, "-") do
      case run(repo, ["cat-file", "-e", oid <> "^{commit}"], true) do
        {:ok, _} -> :ok
        _ -> {:error, :unknown_commit}
      end
    else
      {:error, :unknown_commit}
    end
  end

  defp work_tree(repo) do
    if File.dir?(repo) do
      case run(repo, ["rev-parse", "--is-inside-work-tree"], true) do
        {:ok, "true\n"} -> :ok
        _ -> {:error, :not_a_work_tree}
      end
    else
      {:error, :not_a_work_tree}
    end
  end

  # Listings keep stderr out of their NUL-separated output (it goes to the
  # service's journal); yes/no checks fold it in, where nothing parses it.
  defp run(repo, args, merge_stderr \\ false) do
    case System.cmd("git", @safe ++ args, cd: repo, env: @env, stderr_to_stdout: merge_stderr) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {code, out}}
    end
  end
end
