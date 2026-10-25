defmodule Trailblazer.Files do
  @moduledoc """
  A repository's files, listed and read the way ranger lists them.

  The list is `rg --files --no-require-git`: what git would track, plus what
  git does not track but `.gitignore` does not ignore either.
  Vendored deps/vendor/vendored/third_party trees also bypass ignore rules.
  node_modules, _build and target output are excluded. Of the listed paths, the
  files the core can parse are kept, and the empty ones and the very large ones
  are left out. Every path it hands back is relative to the repository, so it
  is the key a definition is stored under.

  Nothing is read from outside the repository. `read/2` resolves the path first
  and compares it with the repository's own resolved path, so `../`, an
  absolute path and a symlink that leads out are all refused with nothing read.
  """

  @ignored_directories ~w(.git node_modules _build target)
  @vendored_directories ~w(deps vendor vendored third_party)
  @doc false
  def ignored_directories, do: @ignored_directories

  @max_bytes 400_000

  @languages %{
    ".ex" => :elixir,
    ".exs" => :elixir,
    ".js" => :javascript,
    ".jsx" => :javascript,
    ".mjs" => :javascript,
    ".cjs" => :javascript,
    ".ts" => :typescript,
    ".tsx" => :tsx,
    ".py" => :python,
    ".md" => :markdown,
    ".c" => :c,
    ".h" => :cpp,
    ".hh" => :cpp,
    ".hpp" => :cpp,
    ".hxx" => :cpp,
    ".cc" => :cpp,
    ".cpp" => :cpp,
    ".cxx" => :cpp,
    ".cu" => :cpp,
    ".cuh" => :cpp,
    ".go" => :go
  }

  @doc """
  Every file of `repo_path` the core reads, as `%{path, lang, size, hash, mtime}`,
  where `path` is relative to the repository and `hash` is the hex sha256 of
  the content.
  """
  @spec list(Path.t()) :: [
          %{
            path: Path.t(),
            lang: atom(),
            size: non_neg_integer(),
            hash: String.t(),
            mtime: integer()
          }
        ]
  def list(repo_path) do
    repo = Path.expand(repo_path)

    repo
    |> rg_files()
    |> Enum.flat_map(&file(repo, &1))
  end

  @doc """
  The entries `list/1` would give for just these paths (relative to the
  repository), by the same rules: a language the core parses, a regular file
  neither empty nor too large, not hidden and not under an ignored directory.
  Paths git names as changed are passed here, so a sync reads only those
  files (design §13.7). Whether git ignores a path is git's to say: callers
  pass what git listed.
  """
  @spec entries(Path.t(), Enumerable.t()) :: [map()]
  def entries(repo_path, rels) do
    repo = Path.expand(repo_path)
    Enum.flat_map(rels, fn rel -> if listable?(rel), do: file(repo, rel), else: [] end)
  end

  # rg skips hidden files and directories by default, and the ignored
  # directories are excluded from both of its passes.
  defp listable?(rel) do
    parts = Path.split(rel)

    Path.type(rel) == :relative and ".." not in parts and
      not Enum.any?(parts, &(String.starts_with?(&1, ".") or &1 in @ignored_directories))
  end

  @doc """
  The content of the file at `rel` inside `repo_path`, or `{:error, :enoent}`
  when there is no such file, or `{:error, :outside_repo}` when the path leads
  out of the repository. A symlink is followed as long as it stays inside.

  The path is resolved and checked before the file is read, and the identity of
  what was read is checked again afterwards: the same resolution, and the same
  file behind it, or the content is thrown away and the read refused. That
  narrows the window in which a directory inside the repository is replaced by a
  symlink to somewhere outside while the read is in flight. It does not exclude
  an adversary who can write inside the repository: see the note in the plan.

  `opts[:after_read]` is a function called between the read and the second
  check, which is how the race is made deterministic in the tests. Nothing else
  should pass it.
  """
  @spec read(Path.t(), Path.t(), keyword()) :: {:ok, binary()} | {:error, :outside_repo | :enoent}
  def read(repo_path, rel, opts \\ []) do
    with {:ok, repo} <- canonical_path(repo_path),
         {:ok, path} <- canonical_path(target(repo, rel)),
         true <- inside?(repo, path),
         {:ok, %File.Stat{type: :regular} = before} <- File.stat(path),
         {:ok, content} <- File.read(path),
         :ok <- run_hook(opts[:after_read]),
         :ok <- unchanged?(repo, path, before) do
      {:ok, content}
    else
      false -> {:error, :outside_repo}
      {:error, :outside_repo} -> {:error, :outside_repo}
      {:error, _reason} -> {:error, :enoent}
      _other -> {:error, :enoent}
    end
  end

  # An absolute path is taken as it is; a relative one is taken from the repo.
  defp target(repo, rel) do
    if Path.type(rel) == :absolute, do: rel, else: Path.join(repo, rel)
  end

  defp run_hook(nil), do: :ok
  defp run_hook(hook) when is_function(hook, 0), do: hook.()

  # What was read must still be the file that was checked, and still be inside
  # the repository.
  defp unchanged?(repo, path, before) do
    case canonical_path(path) do
      {:ok, after_path} ->
        cond do
          not inside?(repo, after_path) ->
            {:error, :outside_repo}

          true ->
            case File.stat(after_path) do
              {:ok, %File.Stat{type: :regular} = now} ->
                if now.major_device == before.major_device and now.inode == before.inode,
                  do: :ok,
                  else: {:error, :outside_repo}

              {:error, :enoent} ->
                {:error, :enoent}

              {:error, _reason} ->
                {:error, :outside_repo}
            end
        end

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, _reason} ->
        {:error, :outside_repo}
    end
  end

  # Listing

  defp file(repo, rel) do
    path = Path.join(repo, rel)

    with lang when not is_nil(lang) <- lang_of(rel),
         {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} <-
           File.stat(path, time: :posix),
         true <- size > 0 and size <= @max_bytes,
         {:ok, content} <- File.read(path) do
      [%{path: rel, lang: lang, size: size, hash: sha256(content), mtime: mtime}]
    else
      _other -> []
    end
  end

  # ranger matches a suffix whatever its case, and so does this
  defp lang_of(path) do
    Map.get(@languages, path |> Path.extname() |> String.downcase())
  end

  # --null: a path may hold a newline, and rg separates with NUL so that one
  # such file does not become two, or none.
  @doc """
  Whether `rel` is inside a vendored tree (`deps/`, `vendor/`, `vendored/`,
  `third_party/`), which the listing includes even where git ignores it.
  """
  def vendored?(rel), do: Enum.any?(Path.split(rel), &(&1 in @vendored_directories))

  defp rg_files(repo) do
    args = ["--files", "--no-require-git", "--null"]
    excludes = Enum.flat_map(@ignored_directories, &["-g", "!**/#{&1}/**"])
    vendored = ["--no-ignore", "-g", "**/{#{Enum.join(@vendored_directories, ",")}}/**"]
    Enum.uniq(rg_files(repo, args ++ excludes) ++ rg_files(repo, args ++ vendored ++ excludes))
  end

  defp rg_files(repo, args) do
    case System.cmd("rg", args, cd: repo, stderr_to_stdout: true) do
      {out, 0} -> String.split(out, "\0", trim: true)
      {_out, 1} -> []
      {out, status} -> raise "rg --files failed in #{repo} (exit #{status}): #{String.trim(out)}"
    end
  end

  # Containment

  @max_links 40

  @doc false
  def canonical_path(path) do
    case Path.split(path) do
      ["/" | parts] -> resolve("/", parts, 0)
      ["~" | parts] -> resolve(System.user_home!(), parts, 0)
      parts -> resolve(File.cwd!(), parts, 0)
    end
  end

  # Resolve the symlinks of a path one component at a time, the way realpath(3)
  # does: `..` after a symlink means the directory the link points at, not the
  # one it sits in, so the components are walked rather than expanded.
  defp resolve(dir, [], _links), do: {:ok, dir}
  defp resolve(dir, [part | rest], links) when part == ".", do: resolve(dir, rest, links)
  defp resolve("/", [".." | rest], links), do: resolve("/", rest, links)
  defp resolve(dir, [".." | rest], links), do: resolve(parent(dir), rest, links)
  defp resolve(_dir, _parts, links) when links > @max_links, do: {:error, :eloop}

  defp resolve(dir, [part | rest], links) do
    case File.read_link(Path.join(dir, part)) do
      {:ok, target} ->
        # a link names its target from the directory it sits in
        case Path.split(target) do
          ["/" | target_parts] -> resolve("/", target_parts ++ rest, links + 1)
          target_parts -> resolve(dir, target_parts ++ rest, links + 1)
        end

      {:error, _not_a_link} ->
        resolve(Path.join(dir, part), rest, links)
    end
  end

  defp parent("/"), do: "/"
  defp parent(dir), do: dir |> Path.dirname() |> Path.expand()

  defp inside?(repo, path) do
    root = String.trim_trailing(repo, "/")
    path == root or String.starts_with?(path, root <> "/")
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
