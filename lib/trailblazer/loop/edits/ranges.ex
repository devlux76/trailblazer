defmodule Trailblazer.Loop.Edits.Ranges do
  @moduledoc "Read-backed range edits: digest checks, anchor-checked splicing and span validation."

  require Logger
  alias Trailblazer.Loop.Edits
  alias Trailblazer.Loop.Edits.Anchors
  alias Trailblazer.Loop.Edits.Paths
  alias Trailblazer.Loop.Edits.Source

  ## Read-backed range edits

  @doc "The notice for a relocated range, for the model and the case evidence."
  def relocation_notice(%{path: path, from: {a, b}, to: {c, d}}),
    do:
      "Note: your range #{a}-#{b} in #{path} was applied as lines #{c}-#{d}, " <>
        "where your first/last quotes are. Verify that is the code you meant in the current source.\n"

  @doc false
  def log_relocation(relocation),
    do: Logger.warning("trailblazer: edit relocated " <> relocation_notice(relocation))

  @doc false
  def apply_ranges(_worktree, []), do: {:ok, %{}, []}

  def apply_ranges(worktree, blocks) do
    blocks
    |> Enum.group_by(&Paths.target_key(worktree, &1.path))
    |> Enum.reduce_while({:ok, %{}, []}, fn {_, group}, {:ok, contents, moved} ->
      case apply_range_group(worktree, hd(group).path, group) do
        {:ok, rel, text, relocations} ->
          {:cont, {:ok, Map.put(contents, rel, text), moved ++ relocations}}

        {:error, failures} ->
          {:halt, {:error, failures}}
      end
    end)
  end

  defp apply_range_group(worktree, path, blocks) do
    case Paths.contained(worktree, path) do
      {:error, reason} when is_atom(reason) ->
        {:error, Enum.map(blocks, &Edits.failure(&1, reason, ""))}

      {:ok, rel} ->
        with {:ok, text} <- read_full(Path.join(worktree, rel)),
             :ok <- check_digests(blocks, text),
             {:ok, offsets} <- Source.line_offsets(text),
             blocks = Anchors.fill_anchors(blocks, text),
             :ok <- validate_ranges(blocks, length(offsets) - 1, text),
             {:ok, blocks} <- Anchors.check_anchors(blocks, text),
             :ok <- check_spans(blocks, offsets) do
          rel = Path.relative_to(Paths.target_key(worktree, rel), Paths.target_key(worktree, "."))

          relocations =
            for %{relocated_from: from} = b <- blocks,
                do: %{path: b.path, from: from, to: {b.start, b.end}}

          {:ok, rel, splice_all(text, blocks, offsets), relocations}
        else
          {:error, :no_such_file} ->
            {:error, Enum.map(blocks, &Edits.failure(&1, :no_such_file, ""))}

          {:error, :unreadable} ->
            {:error, Enum.map(blocks, &Edits.failure(&1, :unreadable, ""))}

          {:error, failures} ->
            {:error, failures}
        end
    end
  end

  defp read_full(full) do
    case File.read(full) do
      {:ok, text} -> {:ok, text}
      {:error, :enoent} -> {:error, :no_such_file}
      {:error, _} -> {:error, :unreadable}
    end
  end

  # A block without a digest (the text coder's dialect) relies on its
  # first/last quotes alone.
  defp check_digests(blocks, text) do
    sha = Source.sha256(text)
    mismatched = Enum.reject(blocks, &(is_nil(&1.digest) or &1.digest == sha))

    case mismatched do
      [] ->
        :ok

      _ ->
        {:error,
         Enum.map(mismatched, &Edits.failure(&1, :stale_digest, digest_hint(&1, text, sha)))}
    end
  end

  # The excerpt is the exact current source at the failing range (bounded),
  # or just the digest when the window is too large to show.
  defp digest_hint(block, text, sha) do
    hint = "current sha256: #{sha}\n"

    case Source.excerpt(text, block.start, max(block.start, block.end)) do
      nil -> hint
      lines -> hint <> lines
    end
  end

  defp validate_ranges(blocks, len, _text) do
    Enum.reduce_while(blocks, :ok, fn block, :ok ->
      cond do
        not is_integer(block.start) or not is_integer(block.end) ->
          {:halt,
           {:error,
            Enum.map(blocks, &Edits.failure(&1, :invalid_range, "start and end must be integers"))}}

        # no digest (text mode): the first/last quotes alone bind the range
        is_nil(block.digest) and
            not (is_binary(Map.get(block, :first)) and is_binary(Map.get(block, :last))) ->
          {:halt,
           {:error,
            Enum.map(
              blocks,
              &Edits.failure(&1, :invalid_range, "first and last quotes are required")
            )}}

        block.start < 1 or block.start > len + 1 ->
          {:halt,
           {:error,
            Enum.map(blocks, &Edits.failure(&1, :invalid_range, "start is out of the file"))}}

        block.end < block.start - 1 ->
          {:halt,
           {:error,
            Enum.map(blocks, &Edits.failure(&1, :invalid_range, "end precedes start - 1"))}}

        block.end > len ->
          {:halt,
           {:error,
            Enum.map(blocks, &Edits.failure(&1, :invalid_range, "end is out of the file"))}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  # Reject overlapping replacements, insertions strictly inside a replaced
  # span and duplicate insertions at one position. Adjacent disjoint
  # replacements and boundary insertions are valid; same-start operations are
  # sorted deterministically (insertions first, then lowest end).
  defp check_spans(blocks, offsets) do
    span = fn b -> {Enum.at(offsets, b.start - 1), Enum.at(offsets, b.end)} end
    insertion? = fn b -> b.end == b.start - 1 end

    sorted =
      Enum.sort_by(blocks, fn b ->
        {Enum.at(offsets, b.start - 1), if(insertion?.(b), do: 0, else: 1), b.end}
      end)

    Enum.reduce_while(sorted, {:ok, 0, [], MapSet.new()}, fn b, {:ok, max_end, spans, inserts} ->
      {s, e} = span.(b)

      cond do
        insertion?.(b) ->
          cond do
            Enum.any?(spans, fn {rs, re} -> rs < s and s < re end) ->
              {:halt, {:error, [Edits.failure(b, :overlapping_ranges, "")]}}

            MapSet.member?(inserts, s) ->
              {:halt, {:error, [Edits.failure(b, :duplicate_insertion, "")]}}

            true ->
              {:cont, {:ok, max_end, spans, MapSet.put(inserts, s)}}
          end

        s < max_end ->
          {:halt, {:error, [Edits.failure(b, :overlapping_ranges, "")]}}

        true ->
          {:cont, {:ok, max(max_end, e), [{s, e} | spans], inserts}}
      end
    end)
    |> case do
      {:ok, _, _, _} -> :ok
      {:error, failures} -> {:error, failures}
    end
  end

  defp splice_all(text, blocks, offsets) do
    # Descending from the end in original-byte coordinates: splices already
    # applied sit above the current position, so original offsets stay valid
    # and no shift may accumulate. At the same start, a consuming replacement is
    # applied before an insertion so the insertion lands before the replaced
    # bytes, never inside them.
    sorted =
      Enum.sort_by(
        blocks,
        fn b ->
          {b.start, if(b.end == b.start - 1, do: 0, else: 1)}
        end,
        :desc
      )

    Enum.reduce(sorted, text, fn b, acc ->
      a = Enum.at(offsets, b.start - 1)

      case b.end == b.start - 1 do
        true ->
          binary_part(acc, 0, a) <> b.replace <> binary_part(acc, a, byte_size(acc) - a)

        false ->
          b_end = Enum.at(offsets, b.end)

          replacement =
            if b_end < byte_size(text) and b.replace != "" and
                 not String.ends_with?(b.replace, "\n") do
              separator =
                if b_end >= 2 and binary_part(text, b_end - 2, 2) == "\r\n",
                  do: "\r\n",
                  else: "\n"

              b.replace <> separator
            else
              b.replace
            end

          binary_part(acc, 0, a) <> replacement <> binary_part(acc, b_end, byte_size(acc) - b_end)
      end
    end)
  end
end
