defmodule Trailblazer.Indexer.Parse do
  @moduledoc "Reading and parsing one file for the indexer: the parse pool's work, the module node every source file gets, and the dispatch to each language's parser."

  require Logger
  alias Trailblazer.{Config, Files}

  # Languages whose files get a module node of their own (the file's path).
  @file_module_languages [:javascript, :typescript, :tsx, :python, :c, :cpp, :go]

  @doc false
  def file_module_languages, do: @file_module_languages

  # Reading and parsing is what the parse pool is for (Q3): the files that need
  # it are read and parsed at the same time, `parse_workers` of them, and each
  # answers its own path whatever order it finishes in. Elixir and Markdown
  # parse in-process and ride the same stream. Only the reading and the parsing
  # are here; the store writes are not, and wait below for the plan's order.
  # An `{:exit, reason}` is the stream's own verdict on a parse that could not
  # answer, and this sync is that exit, exactly as it was before.
  @doc false
  def parse_outcomes(plan, s) do
    wanted = for {:parse, path, lang} <- plan, do: {path, lang}

    wanted
    |> Task.async_stream(
      fn {path, lang} -> {path, parse_one(s, path, lang)} end,
      max_concurrency: Config.get(:parse_workers),
      ordered: true,
      timeout: :infinity
    )
    |> Stream.map(fn
      {:ok, pair} -> pair
      {:exit, reason} -> exit(reason)
    end)
    |> Map.new()
  end

  defp parse_one(s, path, lang) do
    with {:ok, source} <- read(s, path),
         {:ok, parsed} <- parse_safely(s, path, lang, source) do
      parsed = file_module(parsed, path, lang, source)

      refs = parsed.refs ++ Trailblazer.Parse.Citations.scan(path, source, parsed.nodes)

      module_key =
        if lang in @file_module_languages, do: "#{lang}:module:#{path}##{path}"

      refs =
        if module_key,
          do:
            Enum.map(refs, fn ref ->
              if is_nil(ref.from_key), do: %{ref | from_key: module_key}, else: ref
            end),
          else: refs

      {:ok, %{hash: hash(source), nodes: parsed.nodes, refs: refs}}
    end
  rescue
    # Raised in a task of its own: handed back to this sync's write pass, so a
    # whole sync still answers {:sync_failed, _} and never a crashed worker
    # (E16).
    e -> {:raised, e, __STACKTRACE__}
  catch
    kind, reason -> {:raised, {kind, reason}}
  end

  @doc false
  def read(s, path), do: Keyword.get(s.opts, :read_file, &Files.read/2).(s.path, path)

  defp file_module(parsed, path, lang, source)
       when lang in @file_module_languages do
    lines = String.split(source, "\n")
    last = max(1, length(lines) - if(List.last(lines) == "", do: 1, else: 0))

    module = %{
      key: "#{lang}:module:#{path}##{path}",
      lang: Atom.to_string(lang),
      kind: "module",
      name: path,
      qualified: path,
      path: path,
      start_line: 1,
      end_line: last,
      signature: path,
      text_hash: hash(Enum.take(lines, last) |> Enum.join("\n"))
    }

    children = parsed.refs |> Enum.filter(&(&1.kind == "contains")) |> MapSet.new(& &1.target)

    contains =
      parsed.nodes
      |> Enum.reject(&MapSet.member?(children, &1.qualified))
      |> Enum.map(fn node ->
        %{
          from_key: module.key,
          kind: "contains",
          target: node.qualified,
          arity: nil,
          line: node.start_line,
          ambiguous: false
        }
      end)

    %{parsed | nodes: [module | parsed.nodes], refs: parsed.refs ++ contains}
  end

  defp file_module(parsed, _, _, _), do: parsed
  # A parser that raises on one file must not take the repository down (E16):
  # the file is stale, as after a syntax error, and the crash is logged.
  defp parse_safely(s, path, lang, source) do
    Keyword.get(s.opts, :parse, &parse_file/3).(path, lang, source)
  rescue
    e ->
      Logger.warning(
        "trailblazer: the parser raised on #{path} in #{s.path}: #{Exception.message(e)}"
      )

      {:error, {:parser_raised, Exception.message(e)}}
  end

  @doc false
  def parse_file(path, :elixir, source), do: Trailblazer.Parse.Elixir.parse(path, source)
  def parse_file(path, :markdown, source), do: Trailblazer.Parse.Markdown.parse(path, source)
  def parse_file(path, lang, source), do: Trailblazer.Parse.TreeSitter.parse(path, lang, source)
  @doc false
  def hash(source), do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
end
