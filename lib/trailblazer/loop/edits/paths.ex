defmodule Trailblazer.Loop.Edits.Paths do
  @moduledoc "File-name resolution and worktree containment for edit blocks."

  alias Trailblazer.Files
  alias Trailblazer.Loop.Edits.Matching

  @doc false
  def target_key(worktree, path) do
    full = Path.expand(path, worktree)

    case Files.canonical_path(full) do
      {:ok, canonical} -> canonical
      _ -> full
    end
  end

  ## File names (Aider's find_filename, after the block is parsed)

  @doc false
  def resolve(%{type: :range} = block, _worktree, _files, _shown), do: block

  def resolve(%{} = block, _worktree, _files, _shown) when not is_map_key(block, :search),
    do: block

  def resolve(%{search: search} = block, worktree, files, shown) do
    cond do
      String.trim(search) == "" -> block
      # Codex's review of D17: `../calc.py` was matched to `calc.py` before the
      # containment check saw it. A name that would leave the worktree is
      # refused as written, never repaired into one that does not (A9).
      unsafe_name?(block.path) -> block
      block.path in files -> block
      File.exists?(Path.join(worktree, block.path)) -> block
      files == [] -> by_content(block, worktree, shown)
      true -> block |> resolve_name(files) |> by_content(worktree, shown)
    end
  end

  defp unsafe_name?(path),
    do: Path.type(path) != :relative or ".." in Path.split(path) or String.contains?(path, "\0")

  defp by_content(%{asked: _} = block, _worktree, _shown), do: block

  defp by_content(block, worktree, shown) do
    pool = Map.get(block, :candidates) || shown

    matching =
      Enum.filter(pool, fn path ->
        with {:ok, rel} <- contained(worktree, path),
             {:ok, text} <- File.read(Path.join(worktree, rel)) do
          Matching.replace_most_similar_chunk(text, block.search, block.replace) != nil
        else
          _ -> false
        end
      end)

    case matching do
      [one] -> block |> Map.delete(:candidates) |> Map.merge(%{path: one, asked: block.path})
      _ -> block
    end
  end

  defp resolve_name(block, files) do
    base = Path.basename(block.path)
    same_name = Enum.filter(files, &(Path.basename(&1) == base))

    case same_name do
      [one] ->
        Map.merge(block, %{path: one, asked: block.path})

      [] ->
        case files
             |> Enum.map(&{name_ratio(block.path, &1), &1})
             |> Enum.filter(&(elem(&1, 0) >= 0.8)) do
          [{_, one}] -> Map.merge(block, %{path: one, asked: block.path})
          _ -> block
        end

      several ->
        Map.put(block, :candidates, Enum.take(several, 10))
    end
  end

  defp name_ratio(a, b) do
    matched =
      String.myers_difference(a, b)
      |> Enum.map(fn
        {:eq, text} -> String.length(text)
        _ -> 0
      end)
      |> Enum.sum()

    2 * matched / max(String.length(a) + String.length(b), 1)
  end

  @doc false
  def current(worktree, rel, contents, _block) do
    case Map.fetch(contents, rel) do
      {:ok, text} ->
        {:ok, text}

      :error ->
        case File.read(Path.join(worktree, rel)) do
          {:ok, text} -> {:ok, text}
          {:error, :enoent} -> {:ok, nil}
          {:error, _} -> {:error, :unreadable}
        end
    end
  end

  # The path, relative to the worktree, if it stays inside it: no absolute
  # path, no `..` that climbs out, no symlink leading out. A new file does not
  # exist yet, so the check is made on the nearest path that does, found with
  # lstat so that a link whose target is missing counts as there: such a link
  # cannot be resolved and is refused (Codex's review of L2). Anything that
  # cannot be resolved is refused, never assumed inside.
  # A model that invents a root (/workspace/src/a.ts) means the repository
  # file at the longest tail of that path that exists; that tail is then
  # checked like any relative path. Only for a root that does not exist on
  # this machine: a real outside path (/tmp/calc.py) is never matched to a
  # file inside (A9).
  @doc false
  def contained(worktree, path) do
    case Path.type(path) do
      :relative -> contained_relative(worktree, path)
      _ -> contained_relative(worktree, invented_tail(worktree, path) || path)
    end
  end

  defp invented_tail(worktree, path) do
    parts = path |> Path.split() |> Enum.reject(&(&1 in ["/", ".", ".."]))
    invented? = parts != [] and not File.exists?(Path.join("/", hd(parts)))
    if invented?, do: longest_tail(worktree, parts)
  end

  defp longest_tail(worktree, parts) do
    0..max(length(parts) - 1, 0)//1
    |> Enum.map(&(parts |> Enum.drop(&1) |> Path.join()))
    |> Enum.find(&(&1 != "" and File.regular?(Path.join(worktree, &1))))
  end

  defp contained_relative(worktree, path) do
    with true <- Path.type(path) == :relative,
         {:ok, root} <- worktree |> Path.expand() |> real(),
         full = Path.expand(path, root),
         true <- inside?(full, root),
         {:ok, existing} <- full |> nearest_existing() |> real(),
         true <- inside?(existing, root) do
      {:ok, Path.relative_to(full, root)}
    else
      _ -> {:error, :outside_worktree}
    end
  end

  defp nearest_existing(path) do
    case File.lstat(path) do
      {:ok, _} -> path
      {:error, _} when path == "/" -> path
      {:error, _} -> nearest_existing(Path.dirname(path))
    end
  end

  defp real(path) do
    with {:ok, real} <- Files.canonical_path(path),
         true <- File.exists?(real) do
      {:ok, real}
    else
      _ -> :error
    end
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")
end
