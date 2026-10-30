defmodule Trailblazer.Loop.Prompts do
  @moduledoc """
  What the code model is told: the coder's messages for an attempt, the
  reviewer's for a review in a fresh context (design §7.4), how a review
  answer is read, and the dossier an exhausted task comes back with (§7.5).

  The texts live in `priv/prompts/` and are short on purpose: OpenCode's
  opening prompt is 14,317 tokens, and every token here is one the trail
  cannot use (design §10).
  """

  @dir Path.expand("../../../priv/prompts", __DIR__)
  for name <- ~w(coder reviewer dossier), do: @external_resource(Path.join(@dir, name <> ".md"))
  @coder File.read!(Path.join(@dir, "coder.md"))
  @reviewer File.read!(Path.join(@dir, "reviewer.md"))
  @dossier File.read!(Path.join(@dir, "dossier.md"))

  @doc "The coder's system prompt."
  def coder_system, do: @coder

  @doc "The reviewer's system prompt."
  def reviewer_system, do: @reviewer

  @doc """
  Messages for one attempt. `files` are the named files as `{path, lines}`
  (or `{path, :missing}`), listed by name only: their chunks are in the trail;
  `feedback` is what failed last time (the edit misses, the check's output
  tail or the review's findings), nil on the first attempt.

  `head` is the head start (design §6.5): `:check`, the command the change
  must pass, and `:pattern`, a `{path, text}` test to follow when the request
  asks for a test. Everything that stays the same between attempts comes
  first, including `:evidence` installed-source excerpts shared with the reviewer,
  and what failed is appended last, so the model server's prompt cache
  spares a retry the re-read (E25).
  """
  @spec coder(map(), String.t(), [{String.t(), non_neg_integer() | :missing}], String.t() | nil, map()) ::
          [map()]
  def coder(task, trail, files, feedback \\ nil, head \\ %{}) do
    user =
      [
        section("Request", field(task, :request)),
        section("Design", design(task)),
        section("Trail", trail),
        section("Files", named(files)),
        section("Check", head[:check] && "Your change must pass: `#{head[:check]}`"),
        section("A test to follow", head[:pattern] && file(head[:pattern])),
        section("Installed dependency evidence", evidence(head[:evidence] || [])),
        section("The last attempt failed", feedback)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    [%{role: "system", content: @coder}, %{role: "user", content: user}]
  end

  @doc "Messages for a review of `diff`, in a context of its own."
  @spec reviewer(map(), String.t(), [{String.t(), String.t()}]) :: [map()]
  def reviewer(task, diff, evidence \\ []) do
    user =
      [
        section("Request", field(task, :request)),
        section(
          "Design",
          design(task) || "(none given: judge by the request and the code around the change)"
        ),
        section("Installed dependency evidence", evidence(evidence)),
        section("Diff", fenced(diff, "diff"))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    [%{role: "system", content: @reviewer}, %{role: "user", content: user}]
  end

  @doc """
  Reads a reviewer's answer by its first line that is not blank: `PASS`, or
  `FAIL:` and the findings. Anything else is `{:unclear, text}`, which the
  loop must not take for a pass.
  """
  @spec review_verdict(String.t()) :: :pass | {:fail, String.t()} | {:unclear, String.t()}
  def review_verdict(text) do
    {first, rest} =
      text
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> Enum.drop_while(&(String.trim(&1) == ""))
      |> case do
        [] ->
          {"", []}

        [first | rest] ->
          first = Regex.replace(~r/\A\#{1,6}\s+/, String.trim(first), "")
          {first |> String.trim("*") |> String.trim("`"), rest}
      end

    cond do
      Regex.match?(~r/^PASS\.?$/i, first) ->
        :pass

      Regex.match?(~r/^FAIL\b/i, first) ->
        findings = Regex.replace(~r/^FAIL\W*/i, first, "")
        {:fail, [findings | rest] |> Enum.join("\n") |> String.trim()}

      true ->
        {:unclear, text}
    end
  end

  @doc """
  The dossier (design §7.5). `attempts` are maps with `:n`, `:summary` (what
  was changed) and `:failure` (why it failed).
  """
  @spec dossier(map()) :: String.t()
  def dossier(d) do
    attempts =
      d
      |> Map.get(:attempts, [])
      |> Enum.map_join("\n\n", fn a ->
        "### Attempt #{a[:n]}\n\nChanged: #{a[:summary] || "nothing applied"}\n\nFailed:\n\n" <>
          fenced(a[:failure] || "(no reason recorded)", "")
      end)

    fill(@dossier, %{
      "case" => d[:case],
      "attempt_count" => length(Map.get(d, :attempts, [])),
      "request" => d[:request],
      "from" => d[:from] || "cli",
      "repo" => d[:repo],
      "branch" => d[:branch],
      "worktree" => d[:worktree],
      "trail" => d[:trail],
      "attempts" => attempts,
      "diagnosis" => d[:diagnosis]
    })
  end

  ## Helpers

  defp field(map, key), do: map[key] || map[to_string(key)]

  defp design(task) do
    case field(task, :design) do
      nil -> nil
      [] -> nil
      list when is_list(list) -> Enum.join(list, "\n\n")
      text when is_binary(text) -> if String.trim(text) == "", do: nil, else: text
    end
  end

  defp evidence(entries), do: Enum.map_join(entries, "\n\n", &file/1)

  defp section(_title, nil), do: nil
  defp section(_title, ""), do: nil
  defp section(title, body), do: "## #{title}\n\n#{body}"

  defp named([]), do: nil

  defp named(files) do
    Enum.map_join(files, "\n", fn
      {path, :missing} -> "#{path}: no such file yet"
      {path, 1} -> "#{path}: 1 line"
      {path, n} -> "#{path}: #{n} lines"
    end)
  end

  defp file({path, text}), do: "#{path}\n" <> fenced(text, lang(path))

  # A fence longer than any run of backticks in the text, so a file that holds
  # a fence (a README, a prompt) cannot end its own block early.
  defp fenced(text, lang) do
    longest =
      ~r/`+/
      |> Regex.scan(text)
      |> Enum.map(fn [run] -> String.length(run) end)
      |> Enum.max(fn -> 0 end)

    fence = String.duplicate("`", max(3, longest + 1))
    body = if String.ends_with?(text, "\n"), do: text, else: text <> "\n"
    "#{fence}#{lang}\n#{body}#{fence}"
  end

  @langs %{
    ".ex" => "elixir",
    ".exs" => "elixir",
    ".ts" => "typescript",
    ".tsx" => "tsx",
    ".js" => "javascript",
    ".py" => "python",
    ".rs" => "rust",
    ".go" => "go",
    ".c" => "c",
    ".h" => "c",
    ".cpp" => "cpp",
    ".cu" => "cuda",
    ".md" => "markdown"
  }

  defp lang(path), do: Map.get(@langs, Path.extname(path), "")

  defp fill(template, values) do
    Regex.replace(~r/\{\{(\w+)\}\}/, template, fn _, key ->
      case Map.get(values, key) do
        nil -> "(not given)"
        value -> to_string(value)
      end
    end)
  end
end
