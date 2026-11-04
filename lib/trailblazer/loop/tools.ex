defmodule Trailblazer.Loop.Tools do
  @moduledoc """
  The core's questions (design §6.7) as tools the code model may call during
  an attempt, when the trail is not enough: `where`, `uses`, `impact`, `read`
  and `search`.

  Answers are compact text, one line per item, capped at #{12_000}
  characters, because they go into a 65k-token context. A model's call is
  untrusted data (D4): an unknown tool, arguments that are not JSON or have
  the wrong shape, a path outside the repository and a question the core
  cannot answer all come back as a line starting with `error:`, never as an
  exception.

  The graph answers about the watched repository. `read` reads from the
  task's worktree when one is given (`%{repo: path, worktree: path}`), since
  that is the text the model's edits must match. Its answer starts with a
  compact path/sha256/lines header: the sha256 identifies the exact bytes the
  model may edit with a range block.
  """

  alias Trailblazer.{Files, Query}

  @cap 12_000
  @max_items 40
  @read_lines 400
  @names ~w(where uses impact read search)

  @doc "The answer cap, in characters."
  def cap, do: @cap

  @doc "OpenAI tool definitions for the five questions."
  @spec definitions() :: [map()]
  def definitions do
    [
      tool(
        "where",
        "Where a name is defined: each definition with its file and lines.",
        %{
          name: string("A bare, qualified or Module.fun/arity name, e.g. put or Mini.Store.put/2")
        },
        [:name]
      ),
      tool(
        "uses",
        "Who uses a definition: each caller or reference, with the line it is on.",
        %{name: string("The definition's name")},
        [:name]
      ),
      tool(
        "impact",
        "What a change to a definition affects: its users, their users, and so on.",
        %{
          name: string("The definition's name"),
          depth: %{
            type: "integer",
            minimum: 1,
            maximum: 5,
            description: "How far to walk (default 2)"
          }
        },
        [:name]
      ),
      tool(
        "read",
        "Lines of a file in the repository, numbered. The answer starts with a compact path/sha256/lines header: sha256 covers the file's full bytes exactly as read. At most #{@read_lines} lines per call.",
        %{
          path: string("Path relative to the repository root"),
          start: %{type: "integer", minimum: 1, description: "First line (default 1)"},
          end: %{
            type: "integer",
            minimum: 1,
            description: "Last line (default start + #{@read_lines - 1})"
          }
        },
        [:path]
      ),
      tool(
        "search",
        "Definitions matching words or a name: exact names, then meaning, then literal text.",
        %{
          query: string("What to look for"),
          limit: %{type: "integer", minimum: 1, maximum: 20, description: "How many (default 8)"}
        },
        [:query]
      )
    ]
  end

  @doc "Native submission of edits; applying them remains the loop's responsibility."
  def edit_definition do
    tool(
      "submit_edits",
      "Submit all code changes for checking and review. Two block kinds are accepted. Range block: path (repository-relative), sha256 (lowercase hex), start and end (1-based line numbers, inclusive; set end to start-1 to insert before that line), replace. Use an empty search string for a new file. Do not call read/search in the same response.",
      %{
        blocks: %{
          type: "array",
          minItems: 1,
          items: %{
            anyOf: [
              %{
                type: "object",
                additionalProperties: false,
                properties: %{
                  path: string("Repository-relative file path"),
                  search:
                    string(
                      "Exact existing text including whitespace; empty only for a new or empty file"
                    ),
                  replace: string("Replacement text, or entire contents of a new file")
                },
                required: ["path", "search", "replace"]
              },
              %{
                type: "object",
                additionalProperties: false,
                properties: %{
                  path: string("Repository-relative file path"),
                  sha256: %{
                    type: "string",
                    pattern: "^[0-9a-f]{64}$",
                    description: "SHA-256 of the file's full bytes, exactly as read from disk"
                  },
                  start: %{
                    type: "integer",
                    minimum: 1,
                    description: "First line of the range, 1-based and inclusive"
                  },
                  end: %{
                    type: "integer",
                    minimum: 0,
                    description:
                      "Last line of the range, inclusive; end = start - 1 inserts before that line"
                  },
                  replace: string("Replacement text for the range; empty to delete it")
                },
                required: ["path", "sha256", "start", "end", "replace"]
              }
            ]
          }
        }
      },
      [:blocks]
    )
  end

  @doc "Validates model arguments before the existing all-or-nothing edit application."
  def edit_blocks(arguments) when is_binary(arguments) do
    with {:ok, %{"blocks" => [_ | _] = blocks} = args} when map_size(args) == 1 <-
           Jason.decode(arguments),
         {:ok, decoded} <- decode_blocks(blocks) do
      {:ok, decoded}
    else
      _ ->
        {:error,
         "submit_edits requires a nonempty blocks array; each block is either " <>
           "{path, search, replace} strings, or a range block {path, sha256, start, end, replace} " <>
           "with a lowercase 64-hex sha256 and integer line numbers"}
    end
  end

  def edit_blocks(_), do: {:error, "submit_edits arguments must be JSON"}

  @hex64 ~r/\A[0-9a-f]{64}\z/

  defp decode_blocks(blocks) do
    blocks
    |> Enum.reduce_while({:ok, []}, fn block, {:ok, acc} ->
      case decode_block(block) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      other -> other
    end
  end

  defp decode_block(%{"path" => path, "search" => search, "replace" => replace} = block)
       when map_size(block) == 3 do
    if is_binary(path) and path != "" and is_binary(search) and is_binary(replace) do
      {:ok, %{path: path, search: search, replace: replace}}
    else
      {:error, "legacy block needs a non-empty path and string search/replace"}
    end
  end

  defp decode_block(
         %{
           "path" => path,
           "sha256" => sha256,
           "start" => start,
           "end" => last,
           "replace" => replace
         } = block
       )
       when map_size(block) == 5 do
    cond do
      not (is_binary(path) and path != "") ->
        {:error, "range block needs a non-empty path"}

      not (is_binary(sha256) and Regex.match?(@hex64, sha256)) ->
        {:error, "range block sha256 must be a lowercase 64-hex string"}

      not (is_integer(start) and start >= 1) ->
        {:error, "range block start must be an integer >= 1"}

      not (is_integer(last) and last >= 0) ->
        {:error, "range block end must be an integer >= 0"}

      not is_binary(replace) ->
        {:error, "range block replace must be a string"}

      true ->
        {:ok,
         %{path: path, digest: sha256, start: start, end: last, replace: replace, type: :range}}
    end
  end

  defp decode_block(_block),
    do:
      {:error,
       "each block must be exactly {path, search, replace} or {path, sha256, start, end, replace}"}

  @doc "Strict whole-message JSON fallback; code bytes and edit validation stay unchanged."
  def text_edit_blocks(text) when is_binary(text) do
    text = String.trim(text)
    structured? = String.starts_with?(text, ["[", "{", "```json", "```JSON"])

    payload =
      case Regex.run(~r/\A```json[ \t]*\R([\s\S]*)\R```\z/i, text) do
        [_, json] -> json
        _ -> text
      end

    if structured? do
      case Jason.decode(payload) do
        {:ok, blocks} when is_list(blocks) -> edit_blocks(Jason.encode!(%{blocks: blocks}))
        {:ok, args} when is_map(args) -> edit_blocks(Jason.encode!(args))
        _ -> {:error, "structured edits must be one complete JSON array or blocks object"}
      end
    else
      :none
    end
  end

  defp tool(name, description, properties, required) do
    %{
      type: "function",
      function: %{
        name: name,
        description: description,
        parameters: %{
          type: "object",
          properties: properties,
          required: Enum.map(required, &to_string/1)
        }
      }
    }
  end

  defp string(description), do: %{type: "string", description: description}

  @doc """
  Answers one tool call. `arguments` is the JSON text the model sent, or an
  already decoded map. `opts` go to `Trailblazer.Query`.
  """
  @spec call(
          Path.t() | %{repo: Path.t(), worktree: Path.t() | nil},
          String.t(),
          String.t() | map(),
          keyword()
        ) ::
          String.t()
  def call(target, name, arguments, opts \\ [])

  def call(repo, name, arguments, opts) when is_binary(repo),
    do: call(%{repo: repo, worktree: nil}, name, arguments, opts)

  def call(%{repo: _} = target, name, arguments, opts) do
    with :ok <- known(name),
         {:ok, args} <- decode(arguments) do
      name |> answer(target, args, opts) |> capped()
    else
      {:error, message} -> "error: " <> message
    end
  rescue
    e -> "error: #{name} failed: #{Exception.message(e)}"
  catch
    kind, reason -> "error: #{name} failed: #{inspect({kind, reason})}"
  end

  defp known(name) when name in @names, do: :ok

  defp known(name),
    do:
      {:error,
       "no tool named #{inspect(to_string(name))}; the tools are #{Enum.join(@names, ", ")}"}

  defp decode(%{} = args), do: {:ok, args}

  defp decode(text) when is_binary(text) do
    case Jason.decode(if(String.trim(text) == "", do: "{}", else: text)) do
      {:ok, %{} = args} -> {:ok, args}
      {:ok, _other} -> {:error, "arguments must be a JSON object"}
      {:error, e} -> {:error, "arguments are not valid JSON (#{Exception.message(e)})"}
    end
  end

  defp decode(_other), do: {:error, "arguments must be a JSON object"}

  ## The questions

  defp answer("where", t, args, opts) do
    with {:ok, name} <- required_string(args, "where", "name") do
      t.repo
      |> Query.where_declared(name, opts)
      |> lines("no definition named #{inspect(name)}", &definition/1)
    end
  end

  defp answer("uses", t, args, opts) do
    with {:ok, name} <- required_string(args, "uses", "name") do
      t.repo
      |> Query.who_uses(name, opts)
      |> lines("nothing uses #{inspect(name)}", fn u ->
        "#{u.node.path}:#{u.line || u.node.start_line}  #{u.node.qualified}  #{u.kind} #{u.target.qualified}" <>
          uncertain(u.uncertain)
      end)
    end
  end

  defp answer("impact", t, args, opts) do
    with {:ok, name} <- required_string(args, "impact", "name"),
         {:ok, depth} <- optional_integer(args, "impact", "depth", 2, 1..5) do
      t.repo
      |> Query.impact_of(name, depth, opts)
      |> lines("nothing depends on #{inspect(name)}", fn i ->
        "#{i.distance} #{i.via}  #{definition(i.node)}" <> uncertain(i.uncertain)
      end)
    end
  end

  defp answer("read", t, args, _opts) do
    with {:ok, path} <- required_string(args, "read", "path"),
         {:ok, first} <- optional_integer(args, "read", "start", 1, 1..1_000_000_000),
         {:ok, last} <-
           optional_integer(args, "read", "end", first + @read_lines - 1, first..1_000_000_000) do
      last = min(last, first + @read_lines - 1)

      case Files.read(t.worktree || t.repo, path) do
        {:ok, text} ->
          all = text |> String.split(~r/\r?\n/) |> drop_last_empty()
          total = length(all)
          header = "path: #{path}\nsha256: #{sha256(text)}\nlines: #{total}\n"

          body =
            case all |> Enum.with_index(1) |> Enum.slice((first - 1)..(last - 1)//1) do
              [] ->
                "#{path} has #{total} lines, no line #{first}"

              numbered ->
                shown = Enum.map_join(numbered, "\n", fn {line, n} -> "#{n}| #{line}" end)
                {_, shown_last} = List.last(numbered)
                wanted = Map.get(args, "end", total)

                # say where the read stopped, so the model reads on rather than
                # taking a cut file for a short one
                if shown_last < min(wanted, total),
                  do:
                    shown <>
                      "\n... cut at line #{shown_last} of #{total}: read again from #{shown_last + 1}",
                  else: shown
            end

          header <> body

        {:error, :outside_repo} ->
          {:error, "#{path} is outside the repository"}

        {:error, _} ->
          {:error, "no file #{path}"}
      end
    end
  end

  defp answer("search", t, args, opts) do
    with {:ok, query} <- required_string(args, "search", "query"),
         {:ok, limit} <- optional_integer(args, "search", "limit", 8, 1..20) do
      t.repo
      |> Query.search(query, limit, opts)
      |> lines("nothing matches #{inspect(query)}", fn h ->
        "#{:erlang.float_to_binary(h.score / 1, decimals: 2)} #{h.via}  #{definition(h.node)}"
      end)
    end
  end

  defp definition(n) do
    sig = if n.signature in [nil, ""], do: "", else: "  " <> first_line(n.signature)
    stale = if n.stale, do: "  (stale)", else: ""
    "#{n.qualified}  #{n.kind}  #{n.path}:#{n.start_line}-#{n.end_line}#{sig}#{stale}"
  end

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 160)

  defp uncertain(true), do: "  (uncertain)"
  defp uncertain(_), do: ""

  defp lines({:error, :not_watched}, _empty, _fun), do: {:error, "the repository is not watched"}
  defp lines({:error, reason}, _empty, _fun), do: {:error, inspect(reason)}
  defp lines([], empty, _fun), do: empty

  defp lines(items, _empty, fun) do
    shown = items |> Enum.take(@max_items) |> Enum.map_join("\n", fun)
    more = length(items) - @max_items
    if more > 0, do: shown <> "\n... #{more} more not shown", else: shown
  end

  defp drop_last_empty(lines),
    do: if(List.last(lines) == "", do: Enum.drop(lines, -1), else: lines)

  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  ## Arguments

  defp required_string(args, tool, key) do
    case args[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{tool} needs \"#{key}\" (a non-empty string)"}
    end
  end

  defp optional_integer(args, tool, key, default, range) do
    case Map.get(args, key) do
      nil ->
        {:ok, default}

      value when is_integer(value) ->
        if value in range, do: {:ok, value}, else: bad_int(tool, key, range)

      _ ->
        bad_int(tool, key, range)
    end
  end

  defp bad_int(tool, key, first..last//_),
    do: {:error, "#{tool}: \"#{key}\" must be an integer from #{first} to #{last}"}

  ## Output

  defp capped({:error, message}), do: "error: " <> message

  defp capped(text) when byte_size(text) <= @cap, do: text

  defp capped(text) do
    if String.length(text) <= @cap do
      text
    else
      kept = String.slice(text, 0, @cap)
      cut = text |> String.slice(@cap..-1//1) |> String.split("\n") |> length()
      kept <> "\n... cut here: #{cut} more lines (ask for a narrower range)"
    end
  end
end
