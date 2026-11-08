defmodule Trailblazer.Loop.Coordinator.Preflight do
  @moduledoc "Read-only acceptance preflight: the case record, its repository, primary, candidate and checkouts."

  alias Trailblazer.Files
  alias Trailblazer.Loop.Coordinator.Git

  ## Preflight

  @doc false
  def preflight_record(id, record) do
    repo = record["repo"]
    common = record["common"]

    with :ok <- validate_repository(repo, common),
         primary = record["primary"],
         :ok <- validate_primary(primary),
         {:ok, primary_sha} <- primary_sha(repo, primary),
         candidate = record["candidate"],
         :ok <- validate_candidate(candidate, record["stage"]),
         branch = record["branch"],
         :ok <- validate_branch(repo, branch, candidate),
         base = record["base"],
         :ok <- validate_base(repo, base),
         {:ok, checkouts} <- primary_checkouts(repo, primary),
         :ok <- check_primary_checkouts(checkouts, record["files"] || []) do
      {:ok,
       %{
         "case" => id,
         "repo" => repo,
         "common" => common,
         "primary" => primary,
         "primary_sha" => primary_sha,
         "candidate" => candidate,
         "branch" => branch,
         "base" => base,
         "files" => record["files"],
         "primary_checkouts" => checkouts,
         "stage" => record["stage"]
       }}
    end
  end

  defp validate_repository(repo, common) do
    with {:ok, ^repo} <- Files.canonical_path(repo),
         {:ok, ^common} <-
           Git.git(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      :ok
    else
      _ -> {:error, :ownership_changed}
    end
  end

  defp validate_primary(nil), do: {:error, :no_primary}

  defp validate_primary(primary) when is_binary(primary) do
    if valid_primary?(primary) do
      :ok
    else
      {:error, :invalid_primary}
    end
  end

  defp validate_primary(_), do: {:error, :no_primary}

  defp valid_primary?(name) do
    match?(
      {_, 0},
      System.cmd("git", ["check-ref-format", "refs/heads/" <> name], stderr_to_stdout: true)
    )
  end

  defp primary_sha(repo, primary) do
    case Git.git(repo, ["rev-parse", "--verify", "refs/heads/" <> primary]) do
      {:ok, sha} -> {:ok, sha}
      _ -> {:error, :missing_primary}
    end
  end

  defp validate_candidate(nil, _stage), do: {:error, :no_candidate}

  defp validate_candidate(_candidate, stage) do
    if stage == "candidate_ready" do
      :ok
    else
      {:error, :not_candidate_ready}
    end
  end

  defp validate_branch(repo, branch, candidate) do
    case Git.git(repo, ["rev-parse", "--verify", "refs/heads/" <> branch]) do
      {:ok, ^candidate} -> :ok
      {:ok, _} -> {:error, :candidate_moved}
      _ -> {:error, :candidate_moved}
    end
  end

  defp validate_base(repo, base) do
    case Git.git(repo, ["rev-parse", "--verify", base <> "^{commit}"]) do
      {:ok, _} -> :ok
      _ -> {:error, :ownership_changed}
    end
  end

  @doc false
  def primary_checkouts(repo, primary) do
    case Git.git(repo, ["worktree", "list", "--porcelain"]) do
      {:ok, text} ->
        text
        |> String.split("\n\n", trim: true)
        |> Enum.reduce([], fn block, acc ->
          lines = String.split(block, "\n", trim: true)

          path =
            Enum.find_value(lines, fn
              "worktree " <> p -> String.trim(p)
              _ -> nil
            end)

          branch =
            Enum.find_value(lines, fn
              "branch refs/heads/" <> b -> String.trim(b)
              _ -> nil
            end)

          if is_binary(path) and branch == primary do
            [path | acc]
          else
            acc
          end
        end)
        |> Enum.reverse()
        |> then(&{:ok, &1})

      # Unknown checkouts are never treated as none: that could move a
      # checked-out primary behind its worktree's back.
      {:error, reason} ->
        {:error, {:worktree_discovery_failed, reason}}
    end
  end

  @doc false
  def check_primary_checkouts(paths, files) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case Git.git(path, ["status", "--porcelain"]) do
        {:ok, ""} ->
          {:cont, :ok}

        {:ok, status} ->
          lines = String.split(status, "\n", trim: true)

          if Enum.any?(lines, &(not String.starts_with?(&1, "??"))) do
            {:halt, {:error, :dirty_primary}}
          else
            untracked =
              lines
              |> Enum.filter(&String.starts_with?(&1, "??"))
              |> Enum.map(fn
                "?? " <> p -> String.trim(p)
                other -> String.trim(other)
              end)

            if Enum.any?(untracked, &(&1 in (files || []))) do
              {:halt, {:error, :colliding_untracked}}
            else
              {:cont, :ok}
            end
          end

        {:error, _} ->
          {:halt, {:error, :dirty_primary}}
      end
    end)
  end
end
