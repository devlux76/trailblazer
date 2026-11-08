defmodule Trailblazer.Loop.EditBlocks do
  @moduledoc "Parses a reply into edit blocks, applies them, and recognises a looping reply."

  alias Trailblazer.Loop.{Edits, Lifecycle, Outcome, TextAnswers, Tools}
  import Trailblazer.Loop.Ledger, only: [tally: 1, tally: 2, record: 3, tracked: 1, submit_how: 1]

  @doc false
  def blocks(st, %{finish_reason: "length"}) do
    record(st, :edit, %{status: :cut_off})

    {:retry, :cut_off,
     "Your reply was cut off before it ended. Submit fewer, shorter edits #{submit_how(st)}."}
  end

  def blocks(_st, %{edit_blocks: blocks}), do: {:ok, blocks}

  # Text mode answers in the range-block dialect only (Tools.edit_blocks/2):
  # SEARCH/REPLACE text is no longer accepted from it.
  def blocks(%{task: %{edit_mode: :text}} = st, reply) do
    whole =
      if TextAnswers.whole_file?(st.task),
        do:
          TextAnswers.answer_blocks(
            reply.content || "",
            TextAnswers.current_files(st.ws.path, st.task.files)
          ),
        else: :none

    case whole do
      {:ok, [_ | _] = edits} ->
        record(st, :edit, %{status: :whole_files, paths: Enum.map(edits, & &1.path)})
        {:ok, edits}

      {:error, message} ->
        record(st, :edit, %{status: :unparsed, error: message})

        {:retry, :unparsed,
         "Your files could not be used: #{message}. Submit them #{submit_how(st)}."}

      _ ->
        tag_blocks(st, reply)
    end
  end

  def blocks(st, reply) do
    case Tools.text_edit_blocks(reply.content) do
      {:ok, edits} ->
        {:ok, edits}

      {:error, message} ->
        record(st, :edit, %{status: :unparsed, error: message})
        {:retry, :unparsed, message}

      :none ->
        legacy_blocks(st, reply)
    end
  end

  defp tag_blocks(st, reply) do
    case TextAnswers.edit_blocks(
           reply.content,
           {st.ws.path, st.task.files, TextAnswers.whole_file?(st.task)}
         ) do
      {:ok, edits} ->
        {:ok, edits}

      {:error, message} ->
        record(st, :edit, %{status: :unparsed, error: message})

        {:retry, :unparsed,
         "Your edits could not be read: #{message}. Submit them #{submit_how(st)}." <>
           TextAnswers.named_lines(st.ws.path, reply.content)}

      :none ->
        record(st, :edit, %{status: :no_blocks})
        {:retry, :no_blocks, "Your reply had no edits. Submit them #{submit_how(st)}."}
    end
  end

  defp legacy_blocks(st, reply) do
    case Edits.parse(reply.content) do
      {:ok, []} ->
        record(st, :edit, %{status: :no_blocks})

        {:retry, :no_blocks,
         "Your reply had no edits. Submit the path/search/replace blocks #{submit_how(st)}."}

      {:ok, blocks} ->
        {:ok, blocks}

      {:error, message} ->
        record(st, :edit, %{status: :unparsed, error: message})
        {:retry, :unparsed, "Your blocks could not be read:\n\n#{message}"}
    end
  end

  @doc false
  def apply_edits(st, blocks) do
    tally(:previous_edits, blocks)

    relocate = fn r ->
      record(st, :edit, %{status: :relocated, relocation: r})
      tally(:relocations, [r | tally(:relocations)])
    end

    # paths changed before this batch (edits carried from the last attempt)
    carried = if is_list(tally(:changed)), do: tally(:changed), else: []

    case Edits.apply(st.ws.path, blocks,
           files: tracked(st.ws.path),
           shown: Map.get(st.task, :files, []),
           on_relocate: relocate
         ) do
      # The batch applied but changed no byte and the worktree holds no change
      # at all: the model is repeating itself. Said once; a second such batch
      # in a row ends the case. (A batch that only restates edits carried from
      # the last attempt goes on to verification: that attempt may have failed
      # on something flaky.)
      {:ok, []} when carried == [] ->
        record(st, :edit, %{status: :no_change, blocks: blocks})

        if match?(%{why: :no_change}, List.last(st.failures)) do
          {:stop,
           Outcome.report(
             st,
             :failed,
             "no_change: two attempts in a row submitted edits that change nothing.",
             %{attempts: length(st.failures) + 1, reason: :no_change}
           )}
        else
          {:retry, :no_change,
           "Your edits applied but changed nothing: every replacement equals the current text. " <>
             "Change the code the request needs, #{submit_how(st)}."}
        end

      {:ok, paths} ->
        record(st, :edit, %{status: :applied, blocks: blocks, paths: paths})
        tally(:changed, Enum.uniq(tally(:changed) ++ paths))
        tally(:edit_tree, Lifecycle.tree(st.ws, tally(:changed)))
        :ok

      {:error, failures} ->
        record(st, :edit, %{status: :missed, blocks: blocks, failures: failures})

        missing =
          for f <- failures,
              f.reason in [:no_such_file, :no_match] and f.closest == "",
              do: f.block.path

        if st.task.read_rounds == 0 and missing != [] do
          record(st, :error, %{stage: :edits, reason: :source_context_missing, paths: missing})

          {:stop,
           Outcome.report(
             st,
             :failed,
             "source_context_missing: #{Enum.join(missing, ", ")}. " <>
               "Supply literal current SEARCH anchors or authorize read rounds on a fresh admission; no zero-read retry was run.",
             %{attempts: length(st.failures) + 1}
           )}
        else
          {:retry, :edits_missed, Edits.feedback(failures)}
        end
    end
  end

  # A text-mode reply that has started looping is ended by the host there, so
  # what it wrote is applied and checked in seconds instead of at the
  # generation limit. Looping is the same <edit>/<create> block written for the
  # third time, or a third block that changes nothing (a one-line edit whose
  # replacement is its own quoted line; SEARCH equal to REPLACE in old replies).
  @noop_block ~r/^<{5,9} SEARCH>?[ \t]*\R(.*?)\R?^={5,9}[ \t]*\R(.*?)\R?^>{5,9} REPLACE/ms

  @tag_block ~r/<(edit|create)\b[^>]*>.*?<\/\1>/s

  @tag_noop ~r/<edit\b[^>]*\bstart="(\d+)"[^>]*\bend="\1"[^>]*>\s*<first>(.*?)<\/first>.*?<replace>(.*?)<\/replace>\s*<\/edit>/s

  @looping_noops 3

  @doc false
  def looping_blocks?(content) do
    search_noops =
      @noop_block
      |> Regex.scan(content, capture: :all_but_first)
      |> Enum.count(fn [search, replace] -> String.trim(search) == String.trim(replace) end)

    tag_noops =
      @tag_noop
      |> Regex.scan(content, capture: :all_but_first)
      |> Enum.count(fn [_n, first, replace] -> Tools.raw_lines(replace) == first <> "\n" end)

    repeated =
      @tag_block
      |> Regex.scan(content, capture: :first)
      |> Enum.frequencies()
      |> Map.values()
      |> Enum.max(fn -> 0 end)

    search_noops >= @looping_noops or tag_noops >= @looping_noops or repeated >= @looping_noops
  end
end
