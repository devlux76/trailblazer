defmodule Trailblazer.Parse.Elixir.Env do
  @moduledoc """
  The environment the walk reads in, and the source positions and keys it hands out.
  """

  defp numbered(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {line, number} -> {number, line} end)
    |> Map.new()
  end

  @doc false
  def text_hash(env, first, last) do
    lines = for number <- first..max(last, first), do: Map.get(env.lines, number, "")

    lines
    |> Enum.map_join("\n", & &1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  ## Environment

  @doc false
  def env(path, source) do
    %{
      path: path,
      # numbered, so that reading a definition's own lines is a step and not a
      # walk of the whole file
      lines: numbered(source),
      module: nil,
      module_key: nil,
      aliases: %{},
      imports: [],
      defs: MapSet.new(),
      clauses: %{},
      current: nil,
      test: nil,
      describe: [],
      ex_unit: false
    }
  end

  @doc false
  def line_of(meta) when is_list(meta), do: Keyword.get(meta, :line, 1)
  def line_of(_other), do: 1

  @doc false
  def column_of(meta) when is_list(meta), do: Keyword.get(meta, :column, 0)
  def column_of(_other), do: 0

  # Elixir's metadata gives the line an expression ends on only when it ends a
  # block; a one-line expression is ended by the end of its own line.
  @doc false
  def end_line_of(meta) when is_list(meta) do
    meta
    |> Keyword.get_lazy(:end, fn ->
      meta |> Keyword.get(:end_of_expression, []) |> Keyword.get(:line)
    end)
    |> case do
      end_meta when is_list(end_meta) -> Keyword.get(end_meta, :line, Keyword.get(meta, :line, 1))
      line when is_integer(line) -> line
      _other -> Keyword.get(meta, :line, 1)
    end
  end

  def end_line_of(_other), do: 1

  @doc false
  def qualify(nil, name), do: name
  def qualify(module, name), do: "#{module}.#{name}"

  @doc false
  def node_key(env, kind, qualified), do: "elixir:#{kind}:#{env.path}##{qualified}"
end
