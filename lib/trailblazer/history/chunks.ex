defmodule Trailblazer.History.Chunks do
  @moduledoc "Splits a commit's per-file diffs into the chunks that get embedded, and reads the changed line ranges of each chunk."

  alias Trailblazer.Vectors
  import Trailblazer.History.Privacy, only: [tilde: 2]

  # The code embedding cycle's sizes (operator, 2026-11-06): one entry is at
  # most a definition's 2,400 characters (`Embed.node_text/4`), 16 per request.
  @doc_chars 2_400
  @skip_dirs ~w(_build deps node_modules dist)
  @lock_names ~w(package-lock.json mix.lock)
  @hunk_head ~r/\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@([^\n]*)\n/

  @doc false
  def doc_chars, do: @doc_chars

  # {path, patch} per changed file: no deletions, binaries, lock files or
  # build output.
  @doc false
  def file_patches(show) do
    show
    |> String.split(~r/^diff --git /m, trim: true)
    |> Enum.flat_map(fn part ->
      with [_, path] <- Regex.run(~r/^\+\+\+ b\/(.+)$/m, part),
           false <- String.contains?(part, ["\nBinary files ", "\nGIT binary patch"]),
           false <- skipped?(path),
           [_, body] <- String.split(part, ~r/^--- /m, parts: 2) do
        [{path, "--- " <> body}]
      else
        _ -> []
      end
    end)
  end

  defp skipped?(path) do
    parts = Path.split(path)
    name = List.last(parts)

    Enum.any?(parts, &(&1 in @skip_dirs)) or name in @lock_names or
      String.ends_with?(name, ".lock") or String.starts_with?(name, "bun.lock")
  end

  # A file's diff cut at hunk boundaries so request + path + chunk fit the
  # embedder's input; an oversized hunk is split at line boundaries, each
  # piece with its own exact `@@` header (a piece cut inside a run of changes
  # has no context lines, so it applies only with `git apply --unidiff-zero`).
  @doc false
  def chunks(repo, home, c, bug, card, path, request, patch) do
    [header | hunks] = String.split(patch, ~r/^(?=@@ )/m)
    budget = @doc_chars - String.length(request) - String.length(path) - 32

    hunks
    |> Enum.flat_map(&split_hunk(&1, budget - String.length(header)))
    |> Enum.chunk_while(
      "",
      fn hunk, acc ->
        if acc != "" and String.length(header <> acc <> hunk) > budget,
          do: {:cont, header <> acc, hunk},
          else: {:cont, acc <> hunk}
      end,
      fn acc -> {:cont, header <> acc, ""} end
    )
    |> then(fn pieces ->
      total = length(pieces)
      pieces |> Enum.with_index() |> Enum.map(fn {chunk, i} -> {chunk, i, total} end)
    end)
    |> Enum.map(fn {chunk, i, total} ->
      name = Path.basename(repo)

      id =
        :crypto.hash(:sha256, Enum.join([name, c.sha, path, i], <<0>>))
        |> Base.encode16(case: :lower)

      {old_ranges, new_ranges} = changed_ranges(chunk)

      %{
        id: id,
        point: Vectors.point_id(id),
        repo: name,
        repo_path: tilde(repo, home),
        commit: c.sha,
        parent: c.parent,
        date: c.date,
        at: c.at,
        bug: bug,
        card_status: card && card.status,
        path: path,
        chunk: i,
        # how many chunks the file's diff has: recall stitches the whole diff
        # back for display (not part of the embedded text: no re-embed)
        chunks: total,
        request: request,
        patch: chunk,
        old_ranges: old_ranges,
        new_ranges: new_ranges,
        label: "succeeded"
      }
    end)
  end

  # Room for a piece's own `@@ -s,n +s,n @@` line.
  @head_room 48

  defp split_hunk(hunk, budget) do
    with true <- String.length(hunk) > budget and budget > @head_room,
         [head, os, on, ns, nn, context] <- Regex.run(@hunk_head, hunk) do
      body = binary_part(hunk, byte_size(head), byte_size(hunk) - byte_size(head))

      body
      |> String.split(~r/(?<=\n)/, trim: true)
      |> Enum.chunk_while(
        [],
        fn line, acc ->
          # a "\ No newline" marker stays with the line it qualifies
          if acc != [] and not String.starts_with?(line, "\\") and
               String.length(Enum.join(Enum.reverse([line | acc]))) > budget - @head_room,
             do: {:cont, Enum.reverse(acc), [line]},
             else: {:cont, [line | acc]}
        end,
        fn acc -> {:cont, Enum.reverse(acc), []} end
      )
      |> Enum.map_reduce({first(os, on), first(ns, nn), context}, fn lines, {o, n, ctx} ->
        old = Enum.count(lines, &String.starts_with?(&1, [" ", "-"]))
        new = Enum.count(lines, &String.starts_with?(&1, [" ", "+"]))

        piece =
          "@@ -#{start(o, old)},#{old} +#{start(n, new)},#{new} @@#{ctx}\n" <> Enum.join(lines)

        {piece, {o + old, n + new, ""}}
      end)
      |> elem(0)
    else
      _ -> [hunk]
    end
  end

  # The first line a hunk side covers; a side of 0 lines names the line before.
  defp first(s, n), do: if(n == "0", do: String.to_integer(s) + 1, else: String.to_integer(s))
  defp start(line, 0), do: line - 1
  defp start(line, _), do: line

  # The changed lines (not the context) of every hunk in `chunk`, one
  # [first, last] per run of -/+ lines: `{old_ranges, new_ranges}`. A side a
  # run does not touch is [k, k - 1] (empty, before line k).
  defp changed_ranges(chunk) do
    chunk
    |> String.split(~r/^(?=@@ )/m)
    |> Enum.flat_map(fn hunk ->
      case Regex.run(@hunk_head, hunk) do
        [head, os, on, ns, nn, _] ->
          body = binary_part(hunk, byte_size(head), byte_size(hunk) - byte_size(head))
          runs(String.split(body, "\n"), first(os, on), first(ns, nn), nil, [])

        _ ->
          []
      end
    end)
    |> Enum.unzip()
  end

  defp runs([], _o, _n, run, acc), do: Enum.reverse(close(run, acc))

  defp runs([line | rest], o, n, run, acc) do
    case line do
      "-" <> _ -> runs(rest, o + 1, n, bump(run, o, n, 1, 0), acc)
      "+" <> _ -> runs(rest, o, n + 1, bump(run, o, n, 0, 1), acc)
      " " <> _ -> runs(rest, o + 1, n + 1, nil, close(run, acc))
      _ -> runs(rest, o, n, run, acc)
    end
  end

  defp bump(nil, o, n, dm, dp), do: {o, n, dm, dp}
  defp bump({os, ns, m, p}, _o, _n, dm, dp), do: {os, ns, m + dm, p + dp}

  defp close(nil, acc), do: acc
  defp close({os, ns, m, p}, acc), do: [{[os, os + m - 1], [ns, ns + p - 1]} | acc]
end
