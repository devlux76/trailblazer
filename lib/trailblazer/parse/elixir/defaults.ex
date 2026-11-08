defmodule Trailblazer.Parse.Elixir.Defaults do
  @moduledoc """
  The variables a function body binds to a default module, so that a call through
  one of them can be written as a call to that module.

  Two forms qualify: `workspace = mod(st, :workspace, Workspace)` and
  `ws = Keyword.get(opts, :workspace, Workspace)`. The default is an alias, settled
  against the aliases in force. A variable qualifies only when it is bound exactly
  once in the whole function (its parameters count as bindings) and by one of those
  forms. Anything else leaves it out, so no call is guessed at.
  """

  alias Trailblazer.Parse.Elixir.Names

  @doc """
  The variables of one function (its body and its parameters) that name a default
  module, as `%{variable_atom => "Module.Name"}`.
  """
  @spec bindings(term(), map(), [term()]) :: %{atom() => String.t()}
  def bindings(body, env, parameters) do
    occurrences =
      Enum.flat_map(binding_sites(body), fn
        {:direct, var, rhs} -> [{var, {:direct, rhs}}]
        {:pattern, pattern} -> Enum.map(vars(pattern), &{&1, :other})
      end) ++ Enum.map(vars(parameters), &{&1, :other})

    occurrences
    |> Enum.group_by(fn {var, _how} -> var end, fn {_var, how} -> how end)
    |> Enum.flat_map(fn
      {var, [{:direct, rhs}]} ->
        case default_module(rhs, env) do
          {:ok, module} -> [{var, module}]
          :error -> []
        end

      {_var, _bound_otherwise_or_twice} ->
        []
    end)
    |> Map.new()
  end

  # Every place a variable is bound. A direct match `var = rhs` keeps its right side;
  # any other pattern (a destructuring match, a case or fn head, a generator) is a
  # pattern whose variables are each bound there.
  defp binding_sites(body) do
    {_ast, sites} =
      Macro.prewalk(body, [], fn
        {:=, _meta, [{var, _, ctx}, rhs]} = node, acc when is_atom(var) and is_atom(ctx) ->
          {node, [{:direct, var, rhs} | acc]}

        {:=, _meta, [pattern, _rhs]} = node, acc ->
          {node, [{:pattern, pattern} | acc]}

        {:->, _meta, [heads, _body]} = node, acc when is_list(heads) ->
          {node, [{:pattern, heads} | acc]}

        {:<-, _meta, [pattern, _source]} = node, acc ->
          {node, [{:pattern, pattern} | acc]}

        node, acc ->
          {node, acc}
      end)

    sites
  end

  # The variable occurrences in a pattern, or in a parameter list.
  defp vars(pattern) do
    {_ast, found} =
      Macro.prewalk(pattern, [], fn
        {var, _meta, ctx} = node, acc when is_atom(var) and is_atom(ctx) ->
          {node, [var | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp default_module(rhs, env) do
    case default_of(rhs) do
      {:__aliases__, _, _} = default ->
        case Names.resolve_module(default, env) do
          module when is_binary(module) -> {:ok, module}
          _other -> :error
        end

      _other ->
        :error
    end
  end

  defp default_of({:mod, _meta, [_store, _key, default]}), do: default

  defp default_of(
         {{:., _, [{:__aliases__, _, [:Keyword]}, :get]}, _meta, [_opts, _key, default]}
       ),
       do: default

  defp default_of(_other), do: nil
end
