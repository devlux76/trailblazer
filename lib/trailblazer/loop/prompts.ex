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
  for name <- ~w(coder coder_text reviewer dossier),
      do: @external_resource(Path.join(@dir, name <> ".md"))

  @coder File.read!(Path.join(@dir, "coder.md"))
  @coder_text File.read!(Path.join(@dir, "coder_text.md"))
  @coder_whole File.read!(Path.join(@dir, "coder_whole.md"))
  @reviewer File.read!(Path.join(@dir, "reviewer.md"))
  @dossier File.read!(Path.join(@dir, "dossier.md"))

  @doc "The coder's system prompt for an edit mode (`:tool` or `:text`)."
  def coder_system(mode \\ :tool)
  def coder_system(:text), do: @coder_text
  def coder_system(_mode), do: @coder

  @doc "The reviewer's system prompt."
  def reviewer_system, do: @reviewer

  @doc """
  Messages for one attempt. `files` are the named files as `{path, lines}`
  (or `{path, :missing}`), listed by name only: their chunks are in the trail;
  `feedback` is what failed last time (the edit misses, the check's output
  tail or the review's findings), nil on the first attempt.

  `head` is the head start (design §6.5): `:check`, the command the change
  must pass, `:pattern`, a `{path, text}` test to follow when the request
  asks for a test, and `:examples`, the rendered similar past changes
  (`Trailblazer.Loop.Examples`). Everything that stays the same between attempts comes
  first, including `:evidence` installed-source excerpts shared with the reviewer,
  and what failed is appended last, so the model server's prompt cache
  spares a retry the re-read (E25).
  """
  @spec coder(
          map(),
          String.t(),
          [{String.t(), non_neg_integer() | :missing}],
          String.t() | nil,
          map()
        ) ::
          [map()]
  def coder(task, trail, files, feedback \\ nil, head \\ %{}) do
    whole? = Map.get(head, :whole, false)
    system = if whole?, do: @coder_whole, else: coder_system(Map.get(task, :edit_mode, :tool))
    # with a think prefill the trail and history go in the coder's own
    # thinking (coder_think/2), not in the user message
    think? = Map.get(head, :think, false)

    user =
      [
        section("Request", request_text(task, whole?)),
        section("Design", design_text(task, whole?)),
        section("How the repository uses it", head[:usages]),
        unless(think?, do: section("Similar past changes", head[:examples])),
        unless(think?,
          do: section("Trail", if(whole?, do: lean_trail(trail, head), else: trail))
        ),
        section("Files", named(files)),
        section("Current source", sources(head[:sources] || [], whole?)),
        section("Check", head[:check] && "Your change must pass: `#{head[:check]}`"),
        section("A test to follow", head[:pattern] && file(head[:pattern])),
        section("Installed dependency evidence", evidence(head[:evidence] || [])),
        section("The last attempt failed", feedback)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    [%{role: "system", content: system}, %{role: "user", content: user}]
  end

  @doc """
  The coder's prefilled thinking for a think-prefill model (Loop,
  `code_think_prefill`): the trail and the similar past changes, as notes the
  model already holds when it starts answering. Empty when there are none.
  """
  def coder_think(trail, examples) do
    [section("Similar past changes", examples), section("Trail", trail)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  @doc "Messages for a review of `diff`, in a context of its own."
  @spec reviewer(map(), String.t(), [{String.t(), String.t()}], [{String.t(), String.t()}]) ::
          [map()]
  def reviewer(task, diff, evidence \\ [], files \\ []) do
    user =
      [
        section("Request", request_text(task, true)),
        section(
          "Design",
          design_text(task, true) ||
            if(design(task),
              do: nil,
              else: "(none given: judge by the request and the code around the change)"
            )
        ),
        section("Installed dependency evidence", evidence(evidence)),
        section("Diff", fenced(diff, "diff")),
        # the whole changed files: what unchanged lines define is visible (live,
        # 2026-11-06: a diff-only reviewer failed a correct change for "missing"
        # helpers defined above the hunk)
        section("Changed files after the change (complete)", sources(files, true))
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
    # A thinking model may reason in the visible answer and close it with
    # </think> (live, LFM2.5-24B on vortex:9d3e16f: "FAIL: ... wait, it is
    # present ... PASS</think>\nPASS"); only what follows the last close counts.
    text =
      case String.split(text, "</think>") do
        [_only] -> text
        parts -> List.last(parts)
      end

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

  # Text mode only: edits name line ranges and quote their first/last lines,
  # so small named files go whole and numbered as `read` numbers them (the
  # loop bounds them); others stay names, read on demand.
  defp sources([], _whole?), do: nil
  # whole-file mode: plain source (numbers would be copied into the answer);
  # a long file is numbered: it is changed with <edit> ranges, not retyped
  @whole_max_lines 150
  defp sources(files, true), do: Enum.map_join(files, "\n\n", &whole_source/1)
  defp sources(files, _), do: Enum.map_join(files, "\n\n", &numbered_file/1)

  # Whole-file mode reads like a brief to a colleague: the request once (a
  # design already inside it is not repeated) and without the lines that
  # address the host, not the coder (gates, budgets, planner bookkeeping).
  @process ~r/^\s*(?:Compiler gate:|Hard\s*\d+\s*min|Current planner card|Elixir owns|Current checkpoints:|planner (?:note|block|release|start|done) \(|Check:|Independent review|No push|Never merge)/i

  defp request_text(task, false), do: field(task, :request)
  defp request_text(task, true), do: task |> field(:request) |> strip_process()

  defp design_text(task, false), do: design(task)

  defp design_text(task, true) do
    design = task |> design() |> strip_process()
    request = request_text(task, true) || ""

    cond do
      design in [nil, ""] -> nil
      String.contains?(squash(request), squash(design)) -> nil
      true -> design
    end
  end

  # Whole-file mode: the trail keeps every entry from a file being changed
  # (its source is shown whole anyway, so those are its outline) and other
  # entries, in the trail's own order, only while they fit @trail_budget
  # chars (live, 2026-11-06: ~70 entries, 18 KB, for a two-test change).
  @trail_budget 3_000

  @doc false
  def lean_trail(nil, _head), do: nil

  def lean_trail(trail, head) do
    named = MapSet.new(head[:sources] || [], &elem(&1, 0))

    {kept, _} =
      trail
      |> String.split(~r/\n{2,}(?=\S+:\d+-\d+\n)/)
      |> Enum.reduce({[], 0}, fn entry, {kept, used} ->
        path = entry |> String.split(":", parts: 2) |> hd()

        cond do
          # its whole source is in the prompt: the entry becomes an outline
          # line (place + first line), not a repeat (live, vortex:6fb77eb:
          # 9 KB of repeated excerpts in a 16k-token prompt at ~22 tok/s prefill)
          MapSet.member?(named, path) ->
            {[entry |> String.split("\n", parts: 3) |> Enum.take(2) |> Enum.join("\n") | kept],
             used}

          used + byte_size(entry) <= @trail_budget ->
            {[entry | kept], used + byte_size(entry)}

          true ->
            {kept, used}
        end
      end)

    case Enum.reverse(kept) do
      [] -> nil
      entries -> Enum.join(entries, "\n\n")
    end
  end

  @doc false
  def strip_process(nil), do: nil

  def strip_process(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(@process, &1))
    |> Enum.join("\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp squash(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp numbered_file({path, text}) do
    lines = text |> String.split(~r/\r?\n/) |> drop_trailing_empty()
    body = lines |> Enum.with_index(1) |> Enum.map_join("\n", fn {l, n} -> "#{n}| #{l}" end)
    "#{path} (#{length(lines)} lines)\n" <> fenced(body, lang(path))
  end

  defp drop_trailing_empty(lines) do
    if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
  end

  defp named([]), do: nil

  defp named(files) do
    Enum.map_join(files, "\n", fn
      {path, :missing} -> "#{path}: no such file yet"
      {path, 1} -> "#{path}: 1 line"
      {path, n} -> "#{path}: #{n} lines"
    end)
  end

  defp file({path, text}), do: "#{path}\n" <> fenced(text, lang(path))

  defp whole_source({_path, text} = file) do
    lines = text |> String.split(~r/\r?\n/) |> drop_trailing_empty()
    if length(lines) > @whole_max_lines, do: numbered_file(file), else: file(file)
  end

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
