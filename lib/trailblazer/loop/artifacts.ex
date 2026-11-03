defmodule Trailblazer.Loop.Artifacts do
  @moduledoc "Trusted, frozen generation policy; preparation never weakens checked-tree evidence."
  alias Trailblazer.{Files, Loop.Check}

  @excluded ~w(.git node_modules deps _build target)

  def policies(nil, _repos), do: {:ok, %{}}

  def policies(raw, repos) when is_map(raw) do
    try do
      result =
        Map.new(raw, fn {repo, checks} ->
          true = is_binary(repo) and Path.type(repo) == :absolute and is_map(checks)
          {:ok, canonical} = Files.canonical_path(repo)
          admitted = Map.fetch!(repos, canonical)

          selected =
            Map.new(checks, fn {check, policy} ->
              true = check in admitted and valid_body?(policy)
              {check, Map.put(policy, "sha256", digest(policy))}
            end)

          {canonical, selected}
        end)

      {:ok, result}
    rescue
      _ -> {:error, :invalid_artifacts}
    end
  end

  def policies(_, _), do: {:error, :invalid_artifacts}
  def select(policies, repo, check), do: get_in(policies, [repo, check])

  def prepare(root, policy, opts \\ []), do: run(root, policy, :prepare, opts)
  def verify(root, policy, opts \\ []), do: run(root, policy, :verify, opts)

  defp run(root, policy, mode, opts) do
    result =
      with :ok <- frozen(policy),
           :ok <- safe_outputs(root, policy["paths"]),
           {:ok, before} <- snapshot(root),
           {:ok, definitions} <- definition_changes(root, policy["definitions"]) do
        check = Check.run(root, policy["prepare"], opts)

        with :ok <- safe_outputs(root, policy["paths"]),
             {:ok, after_build} <- snapshot(root),
             :ok <- same_git(before, after_build),
             {:ok, paths} <- changes(before.files, after_build.files, policy["paths"]) do
          if check.status == :pass do
            with :ok <- clean(mode, paths) do
              {:ok,
               Map.merge(check, %{
                 command: policy["prepare"],
                 paths: paths,
                 deleted_paths:
                   Enum.filter(paths, &(before.files[&1] != nil and after_build.files[&1] == nil)),
                 definitions_changed: definitions,
                 policy_hash: policy["sha256"]
               })}
            end
          else
            {:error, Map.put(check, :reason, :preparation_failed)}
          end
        end
      end

    case result do
      {:error, reason} when is_atom(reason) -> {:error, %{reason: reason}}
      other -> other
    end
  end

  defp valid_body?(p) do
    is_map(p) and Enum.sort(Map.keys(p)) == ~w(definitions paths prepare) and
      is_binary(p["prepare"]) and String.trim(p["prepare"]) != "" and
      is_list(p["paths"]) and p["paths"] != [] and Enum.all?(p["paths"], &safe_name?/1) and
      is_list(p["definitions"]) and Enum.all?(p["definitions"], &safe_name?/1) and
      Enum.uniq(p["paths"]) == p["paths"] and Enum.uniq(p["definitions"]) == p["definitions"]
  end

  defp frozen(p) when is_map(p) do
    body = Map.delete(p, "sha256")
    if valid_body?(body) and p["sha256"] == digest(body), do: :ok, else: {:error, :invalid_policy}
  end

  defp frozen(_), do: {:error, :invalid_policy}

  defp digest(p) do
    :crypto.hash(:sha256, Jason.encode!([p["prepare"], p["paths"], p["definitions"]]))
    |> Base.encode16(case: :lower)
  end

  defp safe_name?(path) when is_binary(path) and path != "" do
    parts = Path.split(path)

    Path.type(path) == :relative and Path.join(parts) == path and
      not Enum.any?(parts, &(&1 in @excluded or &1 in [".", "..", ".gitmodules"])) and
      not String.contains?(path, ["*", "?", "[", "]", "{", "}"])
  end

  defp safe_name?(_), do: false

  defp safe_outputs(root, paths) do
    if Enum.all?(paths, &safe_output?(root, Path.split(&1))),
      do: :ok,
      else: {:error, :unsafe_output}
  end

  defp safe_output?(root, [part | rest]) do
    path = Path.join(root, part)

    case File.lstat(path) do
      {:error, :enoent} -> true
      {:ok, %{type: :directory}} when rest != [] -> safe_output?(path, rest)
      {:ok, %{type: :regular}} when rest == [] -> true
      _ -> false
    end
  end

  defp snapshot(root) do
    with {:ok, head} <- git(root, ["rev-parse", "HEAD"]),
         {:ok, index} <- git(root, ["ls-files", "--stage", "-z"]),
         false <- Enum.any?(String.split(index, "\0"), &String.starts_with?(&1, "160000 ")),
         {:ok, files} <- walk(root, "", %{}),
         {:ok, files} <- tracked_dependencies(root, index, files) do
      {:ok, %{head: head, index: index, files: files}}
    else
      true -> {:error, :submodules_unsupported}
      {:error, _} -> {:error, :snapshot_failed}
    end
  end

  # Provisioned caches may be large symlinked trees. They are not outputs, but
  # any files actually tracked there still belong to the repository guard.
  defp tracked_dependencies(root, index, files) do
    index
    |> String.split("\0", trim: true)
    |> Enum.map(&(String.split(&1, "\t", parts: 2) |> List.last()))
    |> Enum.filter(&(hd(Path.split(&1)) in @excluded))
    |> Enum.reduce_while({:ok, files}, fn path, {:ok, acc} ->
      case walk(root, path, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
  end

  defp walk(root, rel, files) do
    full = Path.join(root, rel)

    with {:ok, stat} <- File.lstat(full) do
      case stat.type do
        :directory ->
          with {:ok, names} <- File.ls(full) do
            files = Map.put(files, if(rel == "", do: ".", else: rel), {:directory, stat.mode})

            names
            |> Enum.reject(&(rel == "" and &1 in @excluded))
            |> Enum.reduce_while({:ok, files}, fn name, {:ok, acc} ->
              case walk(root, Path.join(rel, name), acc) do
                {:ok, acc} -> {:cont, {:ok, acc}}
                error -> {:halt, error}
              end
            end)
          end

        :regular ->
          with {:ok, digest} <- file_digest(full) do
            {:ok, Map.put(files, rel, {:regular, stat.mode, digest})}
          end

        :symlink ->
          with {:ok, target} <- File.read_link(full) do
            {:ok, Map.put(files, rel, {:symlink, target})}
          end

        other ->
          {:ok, Map.put(files, rel, {other, stat.mode})}
      end
    else
      {:error, :enoent} -> {:ok, files}
      error -> error
    end
  end

  defp file_digest(path) do
    state =
      Enum.reduce(File.stream!(path, 65_536), :crypto.hash_init(:sha256), fn bytes, state ->
        :crypto.hash_update(state, bytes)
      end)

    {:ok, :crypto.hash_final(state)}
  rescue
    error in File.Error -> {:error, error.reason}
  end

  defp same_git(%{head: head, index: index}, %{head: head, index: index}), do: :ok
  defp same_git(_, _), do: {:error, :git_state_changed}

  defp changes(before, after_build, allowed) do
    changed =
      (Map.keys(before) ++ Map.keys(after_build))
      |> Enum.uniq()
      |> Enum.filter(&(before[&1] != after_build[&1]))
      |> Enum.sort()

    outside =
      Enum.reject(changed, fn path ->
        path in allowed or
          (before[path] == nil and match?({:directory, _}, after_build[path]) and
             Enum.any?(allowed, &String.starts_with?(&1, path <> "/")))
      end)

    if outside == [],
      do: {:ok, Enum.filter(changed, &(&1 in allowed))},
      else: {:error, %{reason: :outside_outputs, paths: outside}}
  end

  defp clean(:verify, [_ | _]), do: {:error, :regeneration_required}
  defp clean(_, _), do: :ok

  defp definition_changes(root, definitions) do
    with {:ok, tracked} <-
           git(root, ["diff", "--no-renames", "--name-only", "-z", "HEAD", "--"] ++ definitions),
         {:ok, untracked} <- git(root, ["ls-files", "--others", "-z", "--"] ++ definitions) do
      changed = String.split(tracked <> untracked, "\0", trim: true)
      {:ok, Enum.filter(definitions, &(&1 in changed))}
    end
  end

  defp git(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      _ -> {:error, :git_failed}
    end
  end
end
