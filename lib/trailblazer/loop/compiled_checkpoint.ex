defmodule Trailblazer.Loop.CompiledCheckpoint do
  @moduledoc "Unreviewed, compiling snapshots: real hooked commits and their own current index."
  alias Trailblazer.{Backstop, Files, Indexer}
  alias Trailblazer.Loop.Workspace

  def policies(nil, _repos), do: {:ok, %{}}

  def policies(raw, repos) when is_map(raw) do
    try do
      {:ok,
       Map.new(raw, fn {repo, entries} ->
         {:ok, canonical} = Files.canonical_path(repo)
         admitted = Map.fetch!(repos, canonical)
         true = is_map(entries)

         commands =
           Map.new(entries, fn {check, command} ->
             true = check in admitted and is_binary(command) and String.trim(command) != ""
             {check, command}
           end)

         {canonical, commands}
       end)}
    rescue
      _ -> {:error, :invalid_compilation_policy}
    end
  end

  def policies(_, _), do: {:error, :invalid_compilation_policy}
  def select(policy, repo, check), do: get_in(policy, [repo, check])

  # The execution worktree/HEAD and approved-candidate lifecycle are untouched.
  # One small sibling per case keeps every compiling version, including failed tests.
  def publish(id, source, tree, paths, message, previous, opts \\ []) do
    with {:ok, ws} <- workspace(id, source, previous),
         {:ok, _identity} <- Workspace.identity(ws, source.path),
         {:ok, _} <- git(ws.path, ["read-tree", "--reset", "-u", tree]),
         {:ok, head_tree} <- git(ws.path, ["rev-parse", "HEAD^{tree}"]),
         {:ok, sha} <-
           if(head_tree == tree,
             do: git(ws.path, ["rev-parse", "HEAD"]),
             else: Workspace.commit(ws, message, paths)
           ),
         {:ok, ^tree} <- git(ws.path, ["rev-parse", sha <> "^{tree}"]) do
      indexer = Keyword.get(opts, :indexer, Indexer)
      limit = Keyword.get(opts, :timeout, 30_000)

      index =
        case Backstop.guard(
               :compiled_index,
               id,
               {:ms, max(1, limit)},
               fn -> %{commit: sha, worktree: ws.path} end,
               fn -> refresh(indexer, ws.path, sha) end
             ) do
          {:ok, result} -> result
          {:error, reason} -> %{status: :error, reason: inspect(reason)}
        end

      {:ok,
       %{
         case: id,
         source: source.path,
         ws: ws,
         worktree: ws.path,
         branch: ws.branch,
         commit: sha,
         tree: tree,
         index: index
       }}
    end
  end

  defp workspace(id, source, nil), do: Workspace.open(source.path, id <> "-compiled")

  defp workspace(id, source, %{case: id, source: path, ws: ws}) when path == source.path,
    do: {:ok, ws}

  defp workspace(_, _, _), do: {:error, :checkpoint_owner_changed}

  defp refresh(indexer, path, sha) do
    with {:ok, _} <- indexer.watch(path),
         {:ok, %{head: ^sha} = result} <- indexer.fresh(path) do
      status = indexer.status(path)
      pending = if is_map(status), do: status[:pending_vectors], else: nil
      Map.merge(result, %{status: :current_graph, pending_vectors: pending})
    else
      other -> %{status: :error, reason: inspect(other)}
    end
  end

  def report_failure(repo, id, checkpoint, result, opts \\ []) do
    name = Trailblazer.Vortex.Protocol.repo_name(repo)

    body =
      "Failing tests on compiled candidate #{checkpoint.commit}.\nCase: #{id}\n" <>
        "Source card is in the case record. Compiled branch: #{checkpoint.branch}\n" <>
        "Check: #{result.command}\nExit: #{inspect(result.exit)}\n\n#{result.output_tail}"

    args = [
      "add",
      name,
      "--title",
      "Tests fail on compiled candidate #{String.slice(checkpoint.commit, 0, 12)}",
      "--plan",
      body,
      "--priority",
      "p1"
    ]

    case command(repo, "planner", args, opts) do
      {:ok, {out, 0}} ->
        with {:ok, %{"ref" => ref}} <- Jason.decode(out),
             true <- is_binary(ref),
             do: {:ok, ref},
             else: (_ -> {:error, :invalid_bug_receipt})

      other ->
        {:error, other}
    end
  end

  def resolve(repo, refs, commit, opts \\ []) do
    Enum.map(refs, fn ref ->
      [_, bug] = String.split(ref, ":", parts: 2)
      evidence = "Resolved by independently checked and reviewed candidate #{commit}."

      with {:ok, {_, 0}} <-
             command(
               repo,
               "git",
               ["bug", "comment", "new", bug, "-m", evidence, "--non-interactive"],
               opts
             ),
           {:ok, {_, 0}} <- command(repo, "git", ["bug", "bug", "status", "close", bug], opts),
           {:ok, {_, 0}} <- command(repo, "git", ["bug", "label", "rm", bug, "status:todo"], opts),
           {:ok, {_, 0}} <-
             command(repo, "git", ["bug", "label", "new", bug, "status:done"], opts),
           do: {:ok, ref},
           else: (error -> {:error, ref, error})
    end)
  end

  defp command(repo, executable, args, opts) do
    run =
      Keyword.get(opts, :command, fn exe, argv ->
        path = Path.expand("~/.local/bin") <> ":" <> (System.get_env("PATH") || "")
        System.cmd(exe, argv, cd: repo, stderr_to_stdout: true, env: [{"PATH", path}])
      end)

    Backstop.guard(
      :test_bug_report,
      repo,
      {:ms, max(1, Keyword.get(opts, :timeout, 30_000))},
      fn -> %{command: executable} end,
      fn -> run.(executable, args) end
    )
  end

  defp git(repo, args) do
    case System.cmd("git", ["-c", "core.hooksPath=/dev/null" | args],
           cd: repo,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, {:git, String.trim(out)}}
    end
  end
end
