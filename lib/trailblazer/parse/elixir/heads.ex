defmodule Trailblazer.Parse.Elixir.Heads do
  @moduledoc """
  The heads of definitions and types: their names, arities, defaults and one-line signatures.
  """

  ## Definition heads

  @doc false
  def def_head_and_body(args) do
    case args do
      [{:when, _, [head | rest]} | body] -> {head, body ++ rest}
      [head | body] -> {head, body}
      [] -> {nil, []}
    end
  end

  @doc false
  def def_name({name, _meta, _args}) when is_atom(name), do: name
  def def_name(_other), do: :undefined

  @doc false
  def def_args({_name, _meta, args}) when is_list(args), do: args
  def def_args(_other), do: []

  # `def g(a, b \\ 1)` is both g/1 and g/2.
  @doc false
  def arities(parameters) do
    defaults = Enum.count(parameters, &match?({:\\, _, [_var, _default]}, &1))
    declared = length(parameters)
    smallest = declared - defaults

    if smallest >= declared, do: [declared], else: Enum.to_list(smallest..declared)
  end

  @doc false
  def defaults(parameters) do
    for {:\\, _, [_var, default]} <- parameters, do: default
  end

  @doc false
  def type_name([{:"::", _, [head | _]} | _]), do: head_name(head)
  def type_name([head | _]), do: head_name(head)
  def type_name(_other), do: {"unknown", 0}

  defp head_name({name, _meta, args}) when is_atom(name) do
    {Atom.to_string(name), if(is_list(args), do: length(args), else: 0)}
  end

  defp head_name(_other), do: {"unknown", 0}

  # A signature is one line: the head as the source writes it, with every run
  # of whitespace collapsed, so it can head a line of its own.
  @doc false
  def signature(head) when is_tuple(head) do
    head
    |> Macro.to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def signature(_other), do: ""
end
