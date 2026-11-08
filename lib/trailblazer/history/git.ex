defmodule Trailblazer.History.Git do
  @moduledoc "What the history reads from git and git-bug: the reachable refs, their non-merge commits, the git-bug card each cited bug names, and the git runner."

  @squash "Squashed snapshot"

  @doc false
  def refs(repo) do
    case git(repo, ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/tags"]) do
      {:ok, out} -> {:ok, String.split(out, "\n", trim: true)}
      error -> error
    end
  end

  @doc false
  def commits(_repo, []), do: {:ok, []}

  @doc false
  def commits(repo, refs) do
    format = "--format=%H%x1f%P%x1f%aI%x1f%ct%x1f%B%x1e"

    with {:ok, out} <- git(repo, ["log", "--no-merges", "--reverse", format | refs] ++ ["--"]) do
      commits =
        out
        |> String.split("\x1e", trim: true)
        |> Enum.flat_map(fn record ->
          case String.split(String.trim_leading(record, "\n"), "\x1f", parts: 5) do
            [sha, parents, date, at, message] when sha != "" ->
              [
                %{
                  sha: sha,
                  parent: parents |> String.split(" ", trim: true) |> List.first(),
                  date: date,
                  at: String.to_integer(at),
                  message: String.trim(message)
                }
              ]

            _ ->
              []
          end
        end)
        |> Enum.reject(&String.starts_with?(&1.message, @squash))

      {:ok, commits}
    end
  end

  # One git-bug card per bug id cited in the history: %{title, status, text}.
  # git-bug itself must run (it is in ~/.local/bin, outside the service's
  # PATH): without it every card would silently fall back to the commit
  # message. A cited id with no card still falls back.
  @doc false
  def cards(repo, commits) do
    ids = commits |> Enum.map(&bug(&1.message)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    cond do
      ids == [] ->
        {:ok, %{}}

      match?({:ok, _}, git(repo, ["bug", "version"])) ->
        {:ok, Map.new(ids, &{&1, card(repo, &1)})}

      true ->
        {:error, :git_bug_unavailable}
    end
  end

  defp card(repo, id) do
    with {:ok, out} <- git(repo, ["bug", "bug", "show", id, "--format", "json"]),
         {:ok, %{"title" => title, "status" => status} = card} <- Jason.decode(out) do
      comments = for %{"message" => m} <- card["comments"] || [], is_binary(m), do: m
      %{title: title, status: status, text: Enum.join([title | comments], "\n\n")}
    else
      _ -> nil
    end
  end

  @doc false
  def bug(message) do
    case Regex.run(~r/\bbug:([0-9a-f]{7,})/, message, capture: :all_but_first) do
      [id] -> id
      _ -> nil
    end
  end

  @doc false
  def git(repo, args) do
    path = Enum.join([Path.expand("~/.local/bin"), System.get_env("PATH", "")], ":")

    case System.cmd("git", args, cd: repo, stderr_to_stdout: true, env: [{"PATH", path}]) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, {:git, status, String.slice(out, 0, 300)}}
    end
  rescue
    e -> {:error, {:git, Exception.message(e)}}
  end
end
