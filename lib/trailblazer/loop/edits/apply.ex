defmodule Trailblazer.Loop.Edits.Apply do
  @moduledoc "All-or-nothing application of parsed edit blocks, checked by a patch before any write."

  alias Trailblazer.Loop.Edits
  alias Trailblazer.Loop.Edits.Feedback
  alias Trailblazer.Loop.Edits.Matching
  alias Trailblazer.Loop.Edits.Paths
  alias Trailblazer.Loop.Edits.Ranges
  alias Trailblazer.Loop.Edits.Source

  ## Applying

  @doc """
  Applies the blocks inside `worktree`, all or nothing: every block is matched
  in memory first (several blocks on one file chain), and files are written
  only when all of them matched.

  `opts[:files]` are the repository's files (relative paths). A block with a
  SEARCH that names a file that does not exist is taken to mean the one
  file of that name, or the one close match, as Aider does (a model shown
  `calc.py` wrote `lib/calc.py` three times in the first live trial); a miss
  lists the files with that name. A block that creates a file keeps its name.

  When the name settles nothing (no such file, or several of that name), the
  block goes to the one file among `opts[:shown]` (the files the model was
  given) or those of that name whose text its SEARCH matches: shown `calc.py`,
  the second trial's model wrote `lib/greeting.ex`, the prompt's example (D20).
  """
  @spec apply(Path.t(), [Edits.block()], keyword()) ::
          {:ok, [String.t()]} | {:error, [Edits.failure()]}
  def apply(worktree, blocks, opts \\ []) do
    files = Keyword.get(opts, :files, [])
    shown = Keyword.get(opts, :shown, [])
    blocks = Enum.map(blocks, &normalize/1)
    blocks = Enum.map(blocks, &Paths.resolve(&1, worktree, files, shown))

    case split_by_kind(worktree, blocks) do
      {:error, failures} ->
        {:error, failures}

      {:ok, range_blocks, legacy_blocks} ->
        case Ranges.apply_ranges(worktree, range_blocks) do
          {:error, failures} ->
            {:error, failures}

          {:ok, contents, relocations} ->
            with {:ok, paths} <- apply(worktree, legacy_blocks, contents, files, shown, opts) do
              # Reported only for a batch that was written in full.
              unless opts[:dry_run] do
                on_relocate = Keyword.get(opts, :on_relocate, &Ranges.log_relocation/1)
                Enum.each(relocations, on_relocate)
              end

              {:ok, paths}
            end
        end
    end
  end

  defp apply(worktree, blocks, contents, _files, _shown, opts) do
    {contents, failures} =
      Enum.reduce(blocks, {contents, []}, fn block, {contents, failures} ->
        case edit(worktree, block, contents) do
          {:ok, path, text} -> {Map.put(contents, path, text), failures}
          {:error, failure} -> {contents, [failure | failures]}
        end
      end)

    if failures == [] do
      # only files whose bytes change: a batch that changes nothing returns []
      changed =
        for {path, text} <- contents,
            File.read(Path.join(worktree, path)) != {:ok, text},
            into: %{},
            do: {path, text}

      paths = changed |> Map.keys() |> Enum.sort()

      cond do
        opts[:dry_run] ->
          {:ok, paths}

        true ->
          case write_by_patch(worktree, changed) do
            :ok ->
              {:ok, paths}

            {:error, output} ->
              block = %{path: Enum.join(paths, ", "), type: :patch, search: "", replace: ""}
              {:error, [Edits.failure(block, :patch_failed, output)]}
          end
      end
    else
      {:error, Enum.reverse(failures)}
    end
  end

  # Every batch is checked by vendored tooling before a byte is written: one
  # unified diff (`diff -u`) of all files, applied with `git apply` to scratch
  # copies of the originals outside any repository (so the worktree's
  # autocrlf/eol attributes and symlinks play no part), must reproduce exactly
  # the bytes the edits produced. Only then are the files written, as before
  # (through symlinks). Any disagreement writes nothing.
  defp write_by_patch(_worktree, changed) when map_size(changed) == 0, do: :ok

  defp write_by_patch(worktree, changed) do
    scratch =
      Path.join(System.tmp_dir!(), "trailblazer-patch-#{System.unique_integer([:positive])}")

    tree = Path.join(scratch, "tree")
    File.mkdir_p!(tree)

    try do
      files =
        changed
        |> Enum.sort()
        |> Enum.with_index()
        |> Enum.map(fn {{path, text}, i} ->
          full = Path.join(worktree, path)
          copy = Path.join(tree, path)
          new = Path.join(scratch, "new-#{i}")
          File.write!(new, text)

          old =
            case File.read(full) do
              {:ok, bytes} ->
                File.mkdir_p!(Path.dirname(copy))
                File.write!(copy, bytes)
                bytes

              _ ->
                nil
            end

          %{path: path, full: full, copy: copy, new: new, text: text, old: old}
        end)

      with {:ok, patch, direct} <- unified_diff(files),
           :ok <- git_apply(tree, scratch, patch) do
        direct_paths = MapSet.new(direct, & &1.path)

        case Enum.reject(
               files,
               &(&1.path in direct_paths or File.read(&1.copy) == {:ok, &1.text})
             ) do
          [] ->
            for f <- files do
              File.mkdir_p!(Path.dirname(f.full))
              File.write!(f.full, f.text)
            end

            :ok

          wrong ->
            {:error,
             "git apply produced different bytes than the edits in " <>
               Enum.map_join(wrong, ", ", & &1.path) <> "; nothing was changed"}
        end
      end
    after
      File.rm_rf(scratch)
    end
  end

  defp unified_diff(files) do
    Enum.reduce_while(files, {:ok, "", []}, fn f, {:ok, patch, direct} ->
      {old, old_label} = if f.old, do: {f.copy, "a/" <> f.path}, else: {"/dev/null", "/dev/null"}

      # -a: compare as text even when a file looks binary to diff
      case System.cmd(
             "diff",
             ["-u", "-a", "--label", old_label, "--label", "b/" <> f.path, old, f.new],
             stderr_to_stdout: true
           ) do
        # an empty new file has no hunk to apply: it is written directly
        {"", 0} -> {:cont, {:ok, patch, [f | direct]}}
        {out, 1} -> {:cont, {:ok, patch <> out, direct}}
        {out, _} -> {:halt, {:error, "diff failed for #{f.path}: #{String.trim(out)}"}}
      end
    end)
  end

  defp git_apply(_tree, _scratch, ""), do: :ok

  # Outside any repository: GIT_CEILING_DIRECTORIES stops git from finding one
  # above the scratch tree, and autocrlf is off, so git apply acts as a plain,
  # byte-exact patch tool.
  defp git_apply(tree, scratch, patch) do
    file = Path.join(scratch, "edits.patch")
    File.write!(file, patch)

    case System.cmd(
           "git",
           ["-c", "core.autocrlf=false", "apply", "--whitespace=nowarn", file],
           cd: tree,
           env: [{"GIT_CEILING_DIRECTORIES", scratch}, {"GIT_DIR", nil}, {"GIT_WORK_TREE", nil}],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, _} -> {:error, "git apply refused the edits: #{String.trim(out)}"}
    end
  end

  # A block is either a legacy SEARCH block or a read-backed range block.
  defp normalize(%{type: :search} = block), do: block
  defp normalize(%{type: :range} = block), do: block

  defp normalize(%{path: _, search: _, replace: _} = block),
    do: Map.put(block, :type, :search)

  defp normalize(block), do: block

  defp split_by_kind(worktree, blocks) do
    {range_blocks, legacy_blocks, unknown_blocks} =
      Enum.reduce(blocks, {[], [], []}, fn block, {r, l, u} ->
        case Map.get(block, :type) do
          :range -> {[block | r], l, u}
          :search -> {r, [block | l], u}
          _ -> {r, l, [block | u]}
        end
      end)

    unknown_tmp = Enum.reverse(unknown_blocks)

    cond do
      unknown_tmp != [] ->
        {:error, Enum.map(unknown_tmp, &Edits.failure(&1, :invalid_range, "unknown block type"))}

      true ->
        range_paths =
          blocks
          |> Enum.filter(&(&1.type == :range))
          |> Enum.map(&Paths.target_key(worktree, &1.path))
          |> MapSet.new()

        search_paths =
          blocks
          |> Enum.filter(&(&1.type == :search))
          |> Enum.map(&Paths.target_key(worktree, &1.path))
          |> MapSet.new()

        case MapSet.intersection(range_paths, search_paths) |> Enum.to_list() do
          [] ->
            {:ok, Enum.reverse(range_blocks), Enum.reverse(legacy_blocks)}

          mixed ->
            {:error,
             Enum.map(mixed, fn p ->
               Edits.failure(%{path: p, type: :search, search: "", replace: ""}, :mixed_edits, "")
             end)}
        end
    end
  end

  defp edit(worktree, block, contents) do
    with {:ok, rel} <- Paths.contained(worktree, block.path),
         {:ok, current} <- Paths.current(worktree, rel, contents, block) do
      cond do
        String.trim(block.search) == "" and current in [nil, ""] ->
          {:ok, rel, block.replace}

        String.trim(block.search) == "" ->
          {:ok, offsets} = Source.line_offsets(current)

          hint =
            "sha256: #{Source.sha256(current)}\nFull-file replacement: start: 1, end: #{length(offsets) - 1}\n"

          {:error, Edits.failure(block, :file_exists, hint)}

        current == nil ->
          {:error,
           Edits.failure(
             block,
             :no_such_file,
             block |> Map.get(:candidates, []) |> Enum.join("\n")
           )}

        true ->
          case Matching.replace_most_similar_chunk(current, block.search, block.replace) do
            nil ->
              failure =
                Edits.failure(
                  block,
                  :no_match,
                  Feedback.find_similar_lines(block.search, current)
                )

              {:error, Map.put(failure, :already, already?(current, block.replace))}

            text ->
              {:ok, rel, text}
          end
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, Edits.failure(block, reason, "")}
    end
  end

  defp already?(_current, ""), do: false
  defp already?(current, replace), do: String.contains?(current, String.trim(replace))
end
