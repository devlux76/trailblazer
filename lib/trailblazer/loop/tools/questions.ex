defmodule Trailblazer.Loop.Tools.Questions do
  @moduledoc "The five questions answered for a tool call (where, uses, impact, read, search), with output cap."

  alias Trailblazer.Files
  alias Trailblazer.Query

  @cap 12_000
  @max_items 40
  @read_lines 400

  @doc "The answer cap, in characters."
  def cap, do: @cap

  ## The questions

  @doc false
  def answer("where", t, args, opts) do
    with {:ok, name} <- required_string(args, "where", "name") do
      t.repo
      |> Query.where_declared(name, opts)
      |> lines("no definition named #{inspect(name)}", &definition/1)
    end
  end

  def answer("uses", t, args, opts) do
    with {:ok, name} <- required_string(args, "uses", "name") do
      t.repo
      |> Query.who_uses(name, opts)
      |> lines("nothing uses #{inspect(name)}", fn u ->
        "#{u.node.path}:#{u.line || u.node.start_line}  #{u.node.qualified}  #{u.kind} #{u.target.qualified}" <>
          uncertain(u.uncertain)
      end)
    end
  end

  def answer("impact", t, args, opts) do
    with {:ok, name} <- required_string(args, "impact", "name"),
         {:ok, depth} <- optional_integer(args, "impact", "depth", 2, 1..5) do
      t.repo
      |> Query.impact_of(name, depth, opts)
      |> lines("nothing depends on #{inspect(name)}", fn i ->
        "#{i.distance} #{i.via}  #{definition(i.node)}" <> uncertain(i.uncertain)
      end)
    end
  end

  def answer("read", t, args, opts) do
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
          # a model that invents a root (/testbed/..., /workspace/...) keeps
          # asking for it: the tail that is a real file is read instead
          case relative_tail(t.worktree || t.repo, path) do
            nil ->
              {:error, "#{path} is outside the repository; paths are repository-relative"}

            found ->
              case answer("read", t, Map.put(args, "path", found), opts) do
                text when is_binary(text) ->
                  "note: #{path} is outside the repository; read #{found} (paths are repository-relative)\n" <>
                    text

                other ->
                  other
              end
          end

        {:error, _} ->
          {:error, "no file #{path}"}
      end
    end
  end

  def answer("search", t, args, opts) do
    with {:ok, query} <- required_string(args, "search", "query"),
         {:ok, limit} <- optional_integer(args, "search", "limit", 8, 1..20) do
      t.repo
      |> Query.search(query, limit, opts)
      |> lines("nothing matches #{inspect(query)}", fn h ->
        "#{:erlang.float_to_binary(h.score / 1, decimals: 2)} #{h.via}  #{definition(h.node)}"
      end)
    end
  end

  # Small models invent absolute roots (e.g. /home/x/workspace/src/a.ts): the
  # longest tail of the path that is a real repository file, or nil.
  defp relative_tail(root, path) do
    parts = path |> Path.split() |> Enum.reject(&(&1 in ["/", ".", ".."]))

    0..max(length(parts) - 1, 0)//1
    |> Enum.map(&(parts |> Enum.drop(&1) |> Path.join()))
    |> Enum.find(&(&1 != "" and match?({:ok, _}, Files.read(root, &1))))
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

  @doc false
  def capped({:error, message}), do: "error: " <> message

  def capped(text) when byte_size(text) <= @cap, do: text

  def capped(text) do
    if String.length(text) <= @cap do
      text
    else
      kept = String.slice(text, 0, @cap)
      cut = text |> String.slice(@cap..-1//1) |> String.split("\n") |> length()
      kept <> "\n... cut here: #{cut} more lines (ask for a narrower range)"
    end
  end
end
