defmodule Trailblazer.Trail.Generated do
  @moduledoc """
  Which files of a repository are generated (bundles, compiled output), so the
  trail leaves their definitions out when the source they duplicate is there.

  Two sources, both read once per trail: the `.linelimit-ignore` file at the
  repository root (blank and `#` lines skipped; each other line is a glob
  relative to the root, matched as the pre-commit hook does with bash `[[ == ]]`: `*` crosses
  slashes and `?` is any one character), and git's `linguist-generated` attribute (`true` or
  `set`). Any failure reading either source marks nothing.
  """

  @ignore_file ".linelimit-ignore"

  @doc "A predicate over repository-relative paths: true for generated files."
  @spec matcher(Path.t()) :: (String.t() -> boolean())
  def matcher(repo_root) do
    globs = repo_root |> ignore_file() |> parse_globs() |> Enum.map(&to_regex/1)
    attributed = attributed(repo_root)

    if globs == [] and MapSet.size(attributed) == 0 do
      fn _path -> false end
    else
      fn path ->
        MapSet.member?(attributed, path) or Enum.any?(globs, &Regex.match?(&1, path))
      end
    end
  end

  @doc false
  def parse_globs(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  @doc false
  def to_regex(glob) do
    glob
    |> String.trim_leading("/")
    |> regex_body()
    |> then(&Regex.compile!("^" <> &1 <> "$"))
  end

  # The pre-commit hook that owns .linelimit-ignore matches with bash
  # `[[ $f == $glob ]]`: `*` crosses slashes, `?` is any one character, and
  # there is no globstar. Match exactly as it does.
  defp regex_body("*" <> rest), do: ".*" <> regex_body(rest)
  defp regex_body("?" <> rest), do: "." <> regex_body(rest)
  defp regex_body(<<c::utf8, rest::binary>>), do: Regex.escape(<<c::utf8>>) <> regex_body(rest)
  defp regex_body(""), do: ""

  defp ignore_file(repo_root) do
    case File.read(Path.join(repo_root, @ignore_file)) do
      {:ok, text} -> text
      _missing -> ""
    end
  end

  # One git pipeline: every tracked path into check-attr. Output is NUL-separated
  # triples (path, attribute, value). A failing git leaves nothing marked.
  # Only a repository that has a .gitattributes can set the attribute; skip the
  # git calls (one pass over every tracked file) everywhere else.
  defp attributed(repo_root) do
    if gitattributes?(repo_root), do: check_attr(repo_root), else: MapSet.new()
  end

  defp gitattributes?(repo_root) do
    case System.cmd("git", ["ls-files", "--", ".gitattributes", "**/.gitattributes"],
           cd: repo_root,
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out) != ""
      _ -> false
    end
  rescue
    _ -> false
  end

  defp check_attr(repo_root) do
    command =
      "git ls-files -z 2>/dev/null | git check-attr -z --stdin linguist-generated 2>/dev/null"

    case System.cmd("sh", ["-c", command], cd: repo_root, stderr_to_stdout: false) do
      {out, 0} -> out |> String.split("\0") |> triples(MapSet.new())
      _failed -> MapSet.new()
    end
  rescue
    _no_shell_or_dir -> MapSet.new()
  end

  defp triples([path, "linguist-generated", value | rest], acc) do
    acc = if value in ["true", "set"], do: MapSet.put(acc, path), else: acc
    triples(rest, acc)
  end

  defp triples(_done, acc), do: acc
end
