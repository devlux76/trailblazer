defmodule Trailblazer.Parse.Elixir.Records do
  @moduledoc """
  The accumulator the walk writes into, and the node and reference records it builds.
  """

  alias Trailblazer.Parse.Elixir.Env

  ## Accumulating

  @doc false
  def new_acc, do: %{nodes: [], refs: [], pending: [], seq: 0}

  @doc false
  def add_node(acc, node), do: %{acc | nodes: [node | acc.nodes]}

  @doc false
  def add_ref(acc, env, kind, target, arity, meta) do
    put_ref(acc, acc.seq, from_of(env), kind_in(env, kind), target, arity, Env.line_of(meta))
  end

  # Every reference carries the number the walk gave it, so that the ones
  # settled at the end of a module keep their place among the ones settled as
  # they were read.
  @doc false
  def put_ref(acc, seq, from_key, kind, target, arity, line, ambiguous \\ false) do
    ref = %{
      from_key: from_key,
      kind: kind,
      target: target,
      arity: arity,
      line: line,
      seq: seq,
      ambiguous: ambiguous
    }

    %{acc | seq: acc.seq + 1, refs: [ref | acc.refs]}
  end

  # What a test case exercises is recorded as such, so the resolver and the
  # questions can read it back.
  @doc false
  def from_of(env), do: env.test || env.current || env.module_key

  @doc false
  def kind_in(%{test: nil}, kind), do: kind
  def kind_in(_env, "calls"), do: "tests"
  def kind_in(_env, kind), do: kind

  @doc false
  def add_refs(acc, env, kind, names, meta) do
    Enum.reduce(names, acc, fn {_name, full}, acc ->
      add_ref(acc, env, kind, full, nil, meta)
    end)
  end

  # A module holds what it declares.
  @doc false
  def add_contains(acc, %{module_key: nil}, _qualified, _meta), do: acc

  def add_contains(acc, env, qualified, meta) do
    add_ref(acc, %{env | test: nil, current: nil}, "contains", qualified, nil, meta)
  end

  # The clauses of one function are one definition: its range spans them all.
  @doc false
  def span(clause, %{first: first, last: last, at: at}) do
    %{
      clause
      | first: min(clause.first, first),
        last: max(clause.last, last),
        at: min(clause.at, at)
    }
  end

  # Definitions come out in source order: by where they start, line and column,
  # and the heads that default arguments add before the head the source spells
  # out. The last definition listed at a place is the one its body belongs to.
  @doc false
  def add_clauses(env, acc) do
    env.clauses
    |> Enum.sort_by(fn {_key, clause} -> {clause.at, clause.arity} end)
    |> Enum.reduce(acc, fn {_key, clause}, acc ->
      add_contains(
        add_node(acc, node_at(env, clause, clause.first, clause.last, clause.signature)),
        env,
        clause.qualified,
        line: clause.first
      )
    end)
  end

  defp node_at(env, clause, first, last, signature) do
    %{clause | key: clause.key}
    |> Map.take([:kind, :name, :qualified, :key, :at])
    |> Map.merge(%{
      lang: "elixir",
      path: env.path,
      start_line: first,
      end_line: last,
      signature: String.slice(signature, 0, 200),
      # one hash per line range: two clauses of one function share it
      text_hash: Env.text_hash(env, first, last)
    })
  end

  @doc false
  def node(env, kind, name, qualified, key, meta, signature) do
    first = Env.line_of(meta)
    last = Env.end_line_of(meta)

    %{
      key: key,
      at: {first, Env.column_of(meta)},
      lang: "elixir",
      kind: kind,
      name: name,
      qualified: qualified,
      path: env.path,
      start_line: first,
      end_line: last,
      signature: String.slice(signature, 0, 200),
      # one hash per line range: two clauses of one function share it
      text_hash: Env.text_hash(env, first, last)
    }
  end
end
