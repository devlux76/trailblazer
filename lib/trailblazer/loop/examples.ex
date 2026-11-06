defmodule Trailblazer.Loop.Examples do
  @moduledoc """
  "Similar past changes" for the coder prompt (plan
  `docs/2026-11-05-history-retrieval-plan.md`, Part 3, step 5): the history
  corpus's (`Trailblazer.History`) nearest entries to a task, minus what the
  task must not see, picked by ranger's LFM3 reranker with a selection prompt
  of its own, rendered in the coder's edit format.

  - Query: the request, design and named files, at most an entry's 2,400
    characters; top 200 by vector, no cosine floor (EmbeddingGemma puts related
    and unrelated code in one band, so rank is what carries meaning).
  - Exclusions (mandatory, or the replay eval cheats; missing data excludes):
    any entry of a bug the request cites (`bug:<id>`, either id a prefix of
    the other); in the case's own repository anything not reachable from its
    base (a rebased or side-branch copy of its own fix included); elsewhere
    anything committed at or after the base's time.
  - One candidate per card (or per commit without a card): a card's long
    request repeats across all its entries and would otherwise fill the pool.
  - The reranker sees the best 40 and may answer that none fits (any answer
    naming none counts). When the call fails, the vector ranking stands.
  - Kept: up to 3 examples labelled `succeeded` or `open` (cards stay open
    long after their commits land, so `open` is most of the corpus), and at
    most 1 `fixed_up`/`reverted` one, shown as a caution.
  - Retrieval matches a chunk; the coder is shown the whole change to that
    file (operator, 2026-11-06: as much diff as possible, "we did this once,
    it was similar, and it worked"), stitched from all its chunks. Text mode
    renders each run of changes as an `<edit>` block against the file as it
    was, a new file as `<create>`; tool mode shows the diff. A change whose
    blocks cannot be written exactly, or over the budget, is left out.

  `Trailblazer.Memory`'s rule that nothing reaches a coder prompt is about
  drawn lessons; these are real, labelled history, each shown with its label
  and date, and the loop records the ids it used.
  """

  alias Trailblazer.{Config, History}
  alias Trailblazer.Trail.Rerank

  @recall 200
  @pool 40
  @positives 3
  @cautions 1
  @query_chars 2_400
  @request_chars 300
  @positive ~w(succeeded open)
  @caution ~w(fixed_up reverted)
  @bug_ref ~r/\bbug:([0-9a-f]{7,64})\b/
  # the last group always matches, so unmatched optional counts come back as ""
  @hunk_head ~r/\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))?( @@)/

  @system """
  You choose worked examples for a programmer. You get a change request and numbered past changes from the same codebases, each with its repository, file, outcome, the request it answered and its first changed lines. Pick the past changes that best show how to make this change: the same kind of edit to the same or closely related code (same file, module, function, pattern or API). Leave out changes that only share words or topics with the request.

  Answer with the numbers of up to 5 past changes, best first, separated by commas, for example: 3, 1, 7. If none would help, answer 0. No other text.
  """

  @intro "Changes made before in these codebases, each with its outcome. " <>
           "Their blocks are against those files as they were then: the line numbers are not the current file's. " <>
           "Use them for the form and the style; the current source is the truth."

  @doc """
  The examples for `task` (`:request`, `:design`, `:files`, `:edit_mode`):
  `{:ok, %{text: section | nil, ids: [entry id], how: :rerank | :similarity
  | :empty, considered: n, rerank_error: reason | nil}}`, or `{:error, reason}`
  when the corpus cannot be searched.

  Options: `before:` the base commit's unix time; `reachable:` the set of
  commits reachable from the base in the case's repository; `budget:` characters
  (default `:history_examples_chars`); `similar:` a `History.similar/3`
  stand-in; the rest go to `History.similar/3` and `Rerank.ask/4`.
  """
  @spec recall(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def recall(task, opts \\ []) do
    similar = Keyword.get(opts, :similar, &History.similar/3)

    with {:ok, hits} <- similar.(query(task), @recall, opts) do
      pool = hits |> exclude(task, opts) |> collapse() |> Enum.take(@pool)
      {chosen, how, error} = choose(task, pool, opts)
      budget = Keyword.get_lazy(opts, :budget, fn -> Config.get(:history_examples_chars) end)
      {text, used} = render_all(pick(chosen), Map.get(task, :edit_mode, :tool), budget)

      {:ok,
       %{
         text: text,
         ids: Enum.map(used, & &1["id"]),
         how: how,
         considered: length(pool),
         rerank_error: error
       }}
    end
  end

  @doc false
  def query(task) do
    files = (task[:files] || []) |> List.wrap() |> Enum.join(" ")

    design =
      case task[:design] do
        list when is_list(list) -> Enum.join(list, "\n")
        text -> text || ""
      end

    [task[:request] || "", design, files]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> String.slice(0, @query_chars)
  end

  @doc false
  # The cheat guard, failing closed: an entry of the case's own repository
  # must be an ancestor of the base (`reachable:`, its commit set; a rebased
  # or side-branch copy of the case's own fix is not); any other entry must
  # be committed before the base's time (`before:`). Missing data excludes.
  def exclude(hits, task, opts) do
    bugs = @bug_ref |> Regex.scan(task[:request] || "") |> Enum.map(fn [_, id] -> id end)
    own = task[:repo] && Path.basename(task[:repo])
    reachable = opts[:reachable]
    before = opts[:before]

    Enum.reject(hits, fn {_score, e} ->
      own_bug?(e["bug"], bugs) or not is_binary(e["patch"]) or
        if(e["repo"] == own and reachable,
          do: not MapSet.member?(reachable, e["commit"]),
          else: is_integer(before) and not (is_integer(e["at"]) and e["at"] < before)
        )
    end)
  end

  defp own_bug?(nil, _bugs), do: false

  defp own_bug?(bug, bugs),
    do: Enum.any?(bugs, &(String.starts_with?(bug, &1) or String.starts_with?(&1, bug)))

  # Hits come nearest first, so the first of a card is its best.
  defp collapse(hits), do: Enum.uniq_by(hits, fn {_score, e} -> e["bug"] || e["commit"] end)

  defp choose(_task, [], _opts), do: {[], :empty, nil}

  defp choose(task, pool, opts) do
    numbered =
      pool
      |> Enum.map(fn {score, e} -> %{id: e["id"], entry: e, sim: score} end)
      |> Enum.with_index(1)

    listing = Enum.map_join(numbered, "\n", fn {c, n} -> candidate(c, n) end)
    user = "Change request:\n#{query(task)}\n\nPast changes:\n#{listing}"
    by_id = Map.new(numbered, fn {c, _} -> {c.id, c.entry} end)

    case Rerank.ask(@system, user, numbered, Keyword.put(opts, :allow_none, true)) do
      {:ok, ids} -> {Enum.map(ids, &by_id[&1]), :rerank, nil}
      {:error, reason} -> {Enum.map(pool, &elem(&1, 1)), :similarity, reason}
    end
  end

  defp candidate(%{entry: e, sim: sim}, n) do
    changed =
      e["patch"]
      |> String.split("\n")
      |> Enum.filter(&(&1 =~ ~r/^[+-](?![+-]{2} )/))
      |> Enum.take(3)
      |> Enum.join(" | ")

    "[#{n}] #{e["repo"]} #{e["path"]} (#{e["label"]}) sim=#{Float.round(sim * 1.0, 2)}\n" <>
      "    request: #{one_line(e["request"], 160)}\n    changed: #{one_line(changed, 200)}"
  end

  @doc false
  def pick(entries) do
    {pos, caut} =
      Enum.reduce(entries, {[], []}, fn e, {pos, caut} ->
        cond do
          e["label"] in @positive and length(pos) < @positives -> {[e | pos], caut}
          e["label"] in @caution and length(caut) < @cautions -> {pos, [e | caut]}
          true -> {pos, caut}
        end
      end)

    Enum.reverse(pos) ++ Enum.reverse(caut)
  end

  defp render_all(entries, mode, budget) do
    {parts, used, _room} =
      Enum.reduce(entries, {[], [], budget}, fn e, {parts, used, room} ->
        case render(e, mode) do
          {:ok, text} when byte_size(text) <= room ->
            {[text | parts], [e | used], room - byte_size(text)}

          _ ->
            {parts, used, room}
        end
      end)

    case parts do
      [] -> {nil, []}
      _ -> {Enum.join([@intro | Enum.reverse(parts)], "\n\n"), Enum.reverse(used)}
    end
  end

  @doc """
  One example: a heading with repo, path, outcome and date, the request, and
  the whole change to that file (`"change"`, stitched by `History.similar/3`;
  an entry without the key is taken as whole).
  """
  @spec render(map(), :text | :tool) :: {:ok, String.t()} | :error
  def render(e, mode) do
    patch = Map.get(e, "change", e["patch"])

    body =
      cond do
        not is_binary(patch) -> :error
        mode == :text -> blocks(patch, e["path"])
        true -> {:ok, "```diff\n" <> String.trim_trailing(patch) <> "\n```"}
      end

    with {:ok, body} <- body, :ok <- no_tag_code(patch) do
      date = String.slice(e["date"] || "", 0, 10)

      {:ok,
       "### #{e["repo"]} #{e["path"]} (#{outcome(e["label"])}, #{date})\n" <>
         "Request: #{one_line(e["request"], @request_chars)}\n\n" <> body}
    end
  end

  # Code whose lines start like the edit dialect's own tags (a change to the
  # coder prompt) would read as broken blocks; such an example is left out.
  defp no_tag_code(patch) do
    if Regex.match?(~r/^[ +-][ \t]*<\/?(?:edit|create|replace|first|last)\b/m, patch),
      do: :error,
      else: :ok
  end

  defp outcome("succeeded"), do: "succeeded"
  defp outcome("open"), do: "landed; its card is still open"
  defp outcome("fixed_up"), do: "corrected by a later commit within a day: a caution, not a model"
  defp outcome("reverted"), do: "reverted: a caution, not a model"
  defp outcome(other), do: to_string(other)

  defp one_line(text, chars),
    do: (text || "") |> String.split() |> Enum.join(" ") |> String.slice(0, chars)

  @doc """
  A file's whole unified diff (git's `-U3`) as the coder's text edit blocks
  against the old file: one `<edit>` per run of changes, a `<create>` for a
  new file. History's split pieces (contiguous hunks) are joined back first;
  each hunk's line counts must match its header. `:error` when a block's
  `first`/`last` cannot be known: an insertion whose neighbours are outside
  the diff, or a line the corpus rewrote (`~` for the home directory).
  """
  @spec blocks(String.t(), String.t()) :: {:ok, String.t()} | :error
  def blocks(patch, path) do
    [header | raw] = String.split(patch, ~r/^(?=@@ )/m)

    with false <- raw == [],
         {:ok, hunks} <- parse_hunks(raw),
         hunks = join(hunks),
         false <- Enum.any?(hunks, fn h -> Enum.any?(h.lines, &String.contains?(&1, "~/")) end) do
      if header =~ ~r{^--- /dev/null$}m, do: create(hunks, path), else: edits(hunks, path)
    else
      _ -> :error
    end
  end

  # %{o: first old line, on: old count, n: first new line, nn: new count,
  # lines}; a zero-count side's git start names the line before, so starts
  # are normalised to the first line the side covers (or would).
  defp parse_hunks(raw) do
    Enum.reduce_while(raw, {:ok, []}, fn hunk, {:ok, acc} ->
      with [_, os, on, ns, nn, _] <- Regex.run(@hunk_head, hunk),
           on = count(on),
           nn = count(nn),
           lines = hunk |> String.split("\n") |> tl() |> Enum.reject(&(&1 == "")),
           true <- Enum.count(lines, &String.starts_with?(&1, [" ", "-"])) == on,
           true <- Enum.count(lines, &String.starts_with?(&1, [" ", "+"])) == nn do
        h = %{o: norm(os, on), on: on, n: norm(ns, nn), nn: nn, lines: lines}
        {:cont, {:ok, [h | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, hunks} -> {:ok, Enum.reverse(hunks)}
      :error -> :error
    end
  end

  defp count(""), do: 1
  defp count(n), do: String.to_integer(n)
  defp norm(s, 0), do: String.to_integer(s) + 1
  defp norm(s, _), do: String.to_integer(s)

  # git never emits two hunks that touch (it merges them), so a hunk that
  # starts where the last ended on both sides is a piece History split off.
  defp join(hunks) do
    hunks
    |> Enum.reduce([], fn
      h, [p | rest] when p.o + p.on == h.o and p.n + p.nn == h.n ->
        [%{p | on: p.on + h.on, nn: p.nn + h.nn, lines: p.lines ++ h.lines} | rest]

      h, acc ->
        [h | acc]
    end)
    |> Enum.reverse()
  end

  defp create([%{o: 1, on: 0, n: 1, lines: lines}], path) do
    added = for "+" <> line <- lines, do: line
    {:ok, ~s(<create path="#{path}">\n) <> Enum.join(added, "\n") <> "\n</create>"}
  end

  defp create(_hunks, _path), do: :error

  defp edits(hunks, path) do
    last = length(hunks) - 1

    hunks
    |> Enum.with_index()
    |> Enum.reduce_while([], fn {hunk, i}, acc ->
      case walk(hunk, path, i == last) do
        {:ok, blocks} -> {:cont, acc ++ blocks}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      [] -> :error
      blocks -> {:ok, Enum.join(blocks, "\n")}
    end
  end

  # `o` is the old line number of the next old line; `prev` the text of line
  # o - 1 ("" before line 1, :unknown when outside the hunk). With -U3 a
  # whole hunk ends without context only at the end of the file, so an
  # insertion there (in the diff's last hunk) is past the last line: first "".
  defp walk(hunk, path, last?) do
    st = %{
      o: hunk.o,
      prev: if(hunk.o == 1, do: "", else: :unknown),
      run: nil,
      out: [],
      path: path
    }

    st =
      Enum.reduce(hunk.lines, st, fn
        "\\" <> _, st ->
          st

        " " <> text, st ->
          st |> close(text) |> Map.merge(%{prev: text, o: st.o + 1})

        "-" <> text, st ->
          run = st.run || %{start: st.o, prev: st.prev, removed: [], added: []}
          %{st | run: %{run | removed: run.removed ++ [text]}, o: st.o + 1}

        "+" <> text, st ->
          run = st.run || %{start: st.o, prev: st.prev, removed: [], added: []}
          %{st | run: %{run | added: run.added ++ [text]}}

        _other, st ->
          %{st | out: [:error | st.out]}
      end)
      |> close(if(last?, do: "", else: :unknown))

    if :error in st.out, do: :error, else: {:ok, Enum.reverse(st.out)}
  end

  defp close(%{run: nil} = st, _next), do: st

  defp close(%{run: %{removed: [_ | _] = removed} = run} = st, _next) do
    finish(st, run.start, run.start + length(removed) - 1, hd(removed), List.last(removed), run)
  end

  defp close(%{run: run} = st, next) do
    if next == :unknown or run.prev == :unknown,
      do: %{st | run: nil, out: [:error | st.out]},
      else: finish(st, run.start, run.start - 1, next, run.prev, run)
  end

  defp finish(st, s, e, first, last, run) do
    replace =
      case run.added do
        [] -> "<replace></replace>"
        lines -> "<replace>\n" <> Enum.join(lines, "\n") <> "\n</replace>"
      end

    block =
      ~s(<edit path="#{st.path}" start="#{s}" end="#{e}">\n<first>#{first}</first>\n<last>#{last}</last>\n) <>
        replace <> "\n</edit>"

    %{st | run: nil, out: [block | st.out]}
  end
end
