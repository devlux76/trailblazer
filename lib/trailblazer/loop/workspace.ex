defmodule Trailblazer.Loop.Workspace do
  @moduledoc """
  A task's private Git worktree, forked from HEAD, never the caller's dirty
  checkout. Cleanup is explicit and retains branches; removing a case's branch
  and archiving its evidence belong to `Trailblazer.Loop.Coordinator`, driven
  by the case journal, never by age.
  """
  alias Trailblazer.{Config, Files}
  @source_repo Path.expand("../../..", __DIR__)
  @own_common (case System.cmd("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"],
                      cd: @source_repo,
                      stderr_to_stdout: true
                    ) do
                 {path, 0} -> String.trim_trailing(path, "\n")
                 _ -> nil
               end)

  @own_roots (case System.cmd("git", ["rev-list", "--max-parents=0", "HEAD"],
                     cd: @source_repo,
                     stderr_to_stdout: true
                   ) do
                {roots, 0} -> String.split(roots)
                _ -> []
              end)
  @shared ~w(deps)
  @linked ~w(node_modules)
  @copied ~w(_build target)

  @doc "Whether a path belongs to Trailblazer's own repository, including clones and worktrees."
  def own_repo?(repo) do
    with true <- File.dir?(repo),
         {:ok, common} <- git(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
         {:ok, roots} <- git(repo, ["rev-list", "--max-parents=0", "HEAD"]) do
      own?(repo, common, roots)
    else
      _ -> false
    end
  end

  def open(repo, case_id) do
    with true <- safe_id?(case_id),
         {:ok, repo} <- git(repo, ["rev-parse", "--show-toplevel"]),
         {:ok, common} <- git(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
         {:ok, roots} <- git(repo, ["rev-list", "--max-parents=0", "HEAD"]),
         false <- own?(repo, common, roots),
         {:ok, base} <- git(repo, ["rev-parse", "HEAD"]),
         :ok <- File.mkdir_p(root()),
         path = Path.join(root(), case_id),
         branch = "trailblazer/" <> case_id,
         {:ok, _} <- git(repo, ["worktree", "add", "--no-track", "-b", branch, path, base]) do
      {:ok, %{path: path, branch: branch, base: base}}
    else
      false -> {:error, :bad_case_id}
      true -> {:error, :own_repo}
      error -> error
    end
  end

  @doc "Validated ownership metadata for a durable repair journal."
  def identity(ws, repo) do
    with :ok <- validate(ws),
         {:ok, repo} <- Files.canonical_path(repo),
         {:ok, common} <- git(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
         {:ok, ^common} <-
           git(ws.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      {:ok, %{repo: repo, common: common, path: ws.path, branch: ws.branch, base: ws.base}}
    else
      {:ok, _} -> {:error, :different_repo}
      error -> error
    end
  end

  @doc "Stages only the admitted edit paths and returns their exact candidate tree."
  def tree(ws, paths) do
    with :ok <- validate(ws),
         {:ok, _} <- stage(ws.path, paths),
         {:ok, tree} <- git(ws.path, ["write-tree"]),
         do: {:ok, tree}
  end

  # `paths` limits the diff and the commit to the files the edits changed, so
  # what running the check leaves behind (__pycache__, coverage, a rewritten
  # lock file) is neither reviewed nor committed (D19). Paths are literal
  # pathspecs, never globs.
  def diff(ws, paths \\ :all) do
    :ok = validate(ws)

    {:ok, _} =
      if paths == :all,
        do: git(ws.path, ["add", "--intent-to-add"] ++ pathspec(paths)),
        else: stage(ws.path, paths)

    {:ok, text} = git(ws.path, ["diff", "--no-ext-diff", ws.base] ++ pathspec(paths))
    text
  end

  def commit(ws, message, paths \\ :all) do
    with :ok <- validate(ws),
         {:ok, _} <- stage(ws.path, paths),
         {:ok, _} <- commit_with_hooks(ws.path, message),
         {:ok, sha} <- git(ws.path, ["rev-parse", "HEAD"]),
         do: {:ok, sha}
  end

  # Unlike every other git call here, the commit runs the repository's hooks: the
  # operator's commit rules and UTC restamp apply to worker commits too
  # (trailblazer:6cccd98). git-bug, which the commit-msg hook calls, is in ~/.local/bin.
  defp commit_with_hooks(repo, message) do
    path = Enum.join([Path.expand("~/.local/bin"), System.get_env("PATH", "")], ":")

    case System.cmd("git", ["commit", "--no-gpg-sign", "-m", message],
           cd: repo,
           stderr_to_stdout: true,
           env: [{"PATH", path}]
         ) do
      {_, 0} -> {:ok, :committed}
      {text, _} -> {:error, {:git, String.trim(text)}}
    end
  end

  # A deletion is absent from the index after the first tree capture. Do not
  # ask git add to find it again; its staged deletion remains in the tree/diff.
  defp stage(root, :all), do: git(root, ["add"] ++ pathspec(:all))

  defp stage(root, paths) do
    with {:ok, cached} <- git(root, ["ls-files", "-z"]) do
      cached = String.split(cached, "\0", trim: true)

      present =
        Enum.filter(paths, &(&1 in cached or match?({:ok, _}, File.lstat(Path.join(root, &1)))))

      if present == [], do: {:ok, ""}, else: git(root, ["add"] ++ pathspec(present))
    end
  end

  defp pathspec(:all), do: ["--", ":/"]
  defp pathspec(paths), do: ["--" | Enum.map(paths, &(":(literal)" <> &1))]

  def reset(ws) do
    with :ok <- validate(ws),
         {:ok, _} <- git(ws.path, ["reset", "--hard", ws.base]),
         {:ok, _} <-
           git(
             ws.path,
             ["clean", "-fdx"] ++ Enum.flat_map(@shared ++ @linked ++ @copied, &["-e", &1])
           ),
         do: :ok
  end

  @doc "Shares dependency contents, preserves private workspace link layouts, and copies build outputs."
  # Bun monorepos install node_modules beside each package manifest. Copy their
  # directory/symlink layout so relative workspace aliases resolve this candidate,
  # not the original checkout. Immutable dependency files remain shared by hardlink.
  def provision(ws, repo) do
    with :ok <- validate(ws), do: provision_checkout(ws.path, repo)
  end

  @doc "Provisions a separate linked checkout, including detached verification worktrees."
  def provision_checkout(path, repo) do
    with {:ok, path} <- Files.canonical_path(path),
         {:ok, ^path} <- git(path, ["rev-parse", "--show-toplevel"]),
         {:ok, repo} <- Files.canonical_path(repo),
         {:ok, ^repo} <- git(repo, ["rev-parse", "--show-toplevel"]),
         false <- path == repo,
         {:ok, common} <- git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
         {:ok, ^common} <- git(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
         {:ok, manifests} <-
           git(path, ["ls-files", "-z", "--", "package.json", "**/package.json"]) do
      ws = %{path: path}

      modules =
        manifests
        |> String.split("\0", trim: true)
        |> Enum.map(&Path.join(Path.dirname(&1), "node_modules"))

      names = Enum.uniq(@shared ++ @linked ++ @copied ++ modules)

      with :ok <- copy_dependencies(ws, repo, names) do
        rebase_workspace_links(ws, names)
      end
    else
      true -> {:error, :same_checkout}
      {:ok, _} -> {:error, :different_repo}
      error -> error
    end
  end

  defp copy_dependencies(ws, repo, names) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      source = Path.join(Path.expand(repo), name)
      dest = Path.join(ws.path, name)

      if File.dir?(source) and File.lstat(dest) == {:error, :enoent} do
        result =
          if name in @shared do
            File.ln_s(source, dest)
          else
            flags =
              if Path.basename(name) == "node_modules",
                do: ["-alH"],
                else: ["-a", "--reflink=auto"]

            case System.cmd("cp", flags ++ ["--", source, dest], stderr_to_stdout: true) do
              {_, 0} -> :ok
              {out, code} -> {:error, {:copy, code, out}}
            end
          end

        if result == :ok, do: {:cont, :ok}, else: {:halt, result}
      else
        {:cont, :ok}
      end
    end)
  end

  defp rebase_workspace_links(ws, names) do
    {:ok, root} = Files.canonical_path(ws.path)

    patterns =
      case manifest(Path.join(ws.path, "package.json"))["workspaces"] do
        %{"packages" => paths} when is_list(paths) -> paths
        paths when is_list(paths) -> paths
        _ -> []
      end

    packages =
      for pattern <- patterns,
          is_binary(pattern),
          Path.type(pattern) == :relative,
          ".." not in Path.split(pattern),
          file <- Path.wildcard(Path.join([ws.path, pattern, "package.json"])),
          {:ok, canonical} <- [Files.canonical_path(file)],
          String.starts_with?(canonical, root <> "/"),
          name = manifest(canonical)["name"],
          is_binary(name),
          name not in [".", ".."],
          Regex.match?(~r/\A(?:@[A-Za-z0-9_.-]+\/)?[A-Za-z0-9_.-]+\z/, name),
          do: {name, Path.dirname(canonical)}

    links =
      for directory <- names,
          Path.basename(directory) == "node_modules",
          {name, target} <- packages,
          link = Path.join([ws.path, directory, name]),
          {:ok, _} <- [File.read_link(link)],
          do: {link, target}

    Enum.reduce_while(links, :ok, fn {link, target}, :ok ->
      with {:ok, parent} <- Files.canonical_path(Path.dirname(link)),
           true <- String.starts_with?(parent, root <> "/"),
           :ok <- File.rm(link),
           :ok <- File.ln_s(target, link) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, :dependency_alias_outside_worktree}}
        error -> {:halt, error}
      end
    end)
  end

  defp manifest(path) do
    with {:ok, text} <- File.read(path),
         {:ok, value} when is_map(value) <- Jason.decode(text),
         do: value,
         else: (_ -> %{})
  end

  def close(ws) do
    with :ok <- validate(ws),
         {:ok, common} <-
           git(ws.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
         {:ok, _} <- remove(common, ws.path),
         do: :ok
  end

  # The root-commit check is fixed at compile time and a history rewrite defeats it
  # (trailblazer:d5e9070), so identity also comes from the checked-out project:
  # any HEAD whose mix.exs declares the :trailblazer application is this repository.
  defp own?(repo, common, roots),
    do:
      common == @own_common or Enum.any?(String.split(roots), &(&1 in @own_roots)) or
        trailblazer_project?(repo)

  defp trailblazer_project?(repo) do
    case git(repo, ["show", "HEAD:mix.exs"]) do
      {:ok, mix} -> Regex.match?(~r/\bapp:\s*:trailblazer\b/, mix)
      _ -> false
    end
  end

  defp validate(%{path: path, branch: branch}) do
    with true <- managed?(path, branch),
         {:ok, ^branch} <- git(path, ["symbolic-ref", "--short", "HEAD"]),
         do: :ok,
         else: (_ -> {:error, :not_managed_workspace})
  end

  defp managed?(path, "trailblazer/" <> id) do
    with true <- safe_id?(id),
         {:ok, real_root} <- Files.canonical_path(root()),
         {:ok, real_path} <- Files.canonical_path(path),
         do: real_path == Path.join(real_root, id),
         else: (_ -> false)
  end

  defp managed?(_, _), do: false
  defp safe_id?(id), do: is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/, id)
  defp root, do: Path.join(Config.get(:state_dir), "worktrees")

  defp remove(common, path),
    do: git(File.cwd!(), ["--git-dir", common, "worktree", "remove", "--force", "--", path])

  defp git(repo, args) do
    case System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args,
           cd: repo,
           stderr_to_stdout: true
         ) do
      {text, 0} -> {:ok, String.trim_trailing(text, "\n")}
      {text, _} -> {:error, {:git, String.trim(text)}}
    end
  rescue
    e in ErlangError -> {:error, {:git, Exception.message(e)}}
  end
end
