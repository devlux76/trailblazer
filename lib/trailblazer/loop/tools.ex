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
  that is the text the model's edits must match.
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
        "Lines of a file in the repository, numbered. At most #{@read_lines} lines per call.",
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
