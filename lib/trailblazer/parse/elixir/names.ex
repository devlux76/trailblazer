defmodule Trailblazer.Parse.Elixir.Names do
  @moduledoc """
  The module names a directive or a reference writes, settled against the aliases in force.
  """

  alias Trailblazer.Parse.Elixir.Env

  ## Aliases and imports

  # The names a directive binds: `alias Foo.Bar` binds Bar, `alias Foo.Bar,
  # as: B` binds B, `alias Foo.{A, B}` binds both — and `alias Foo.Bar.{A, B}`
  # binds both under the whole prefix.
  @doc false
  def names_of(target, opts, env) do
    case target do
      {{:., _, [{:__aliases__, _, prefix}, :{}]}, _, members} ->
        full = alias_full(prefix, env)

        Enum.map(members, fn member -> {module_name(member), "#{full}.#{module_name(member)}"} end)

      _other ->
        full = target_full(target, env)
        [{as_name(opts) || last_segment(target), full}]
    end
  end

  # `alias Foo.Bar` binds Bar, which is how a later `Bar` is read.
  defp last_segment({:__aliases__, _, parts}), do: parts |> List.last() |> module_name()
  defp last_segment(target), do: module_name(target)

  @doc false
  def put_aliases(env, names) do
    Enum.reduce(names, env, fn {name, full}, env ->
      %{env | aliases: Map.put(env.aliases, name, full)}
    end)
  end

  defp as_name(opts) do
    case List.flatten(opts) do
      [{:as, {:__aliases__, _, parts}} | _] -> Enum.map_join(parts, ".", &to_string/1)
      [{:as, name}] when is_atom(name) -> Atom.to_string(name)
      _other -> nil
    end
  end

  # `import Foo, only: [put: 2]` admits put/2 and nothing else; `except` is the
  # other way round. Without either, the import admits every name. The options
  # arrive as the one argument after the module, so they are flattened before
  # they are read as a keyword list.
  @doc false
  def import_filter(opts) do
    opts = List.flatten(opts)

    %{
      only:
        case Keyword.get(opts, :only) do
          entries when is_list(entries) -> entries
          _other -> nil
        end,
      except: import_entries(Keyword.get(opts, :except))
    }
  end

  defp import_entries(entries) when is_list(entries), do: entries
  defp import_entries(_other), do: []

  defp target_full({:__aliases__, _, parts}, env), do: alias_full(parts, env)
  defp target_full(target, _env), do: module_name(target)

  @doc false
  def module_name({:__aliases__, _, parts}), do: Enum.map_join(parts, ".", &module_name/1)
  def module_name(name) when is_atom(name), do: Atom.to_string(name)
  def module_name(name) when is_binary(name), do: name
  def module_name(_other), do: "?"

  # Elixir settles a module name on its first segment: the rest is appended.
  # `__MODULE__` stands for the module being written in, so a name written
  # under it is nested in that module.
  defp alias_full(parts, env) do
    case parts do
      [{:__MODULE__, _, nil} | rest] ->
        case Enum.map_join(rest, ".", &module_name/1) do
          "" -> env.module
          nested -> Env.qualify(env.module, nested)
        end

      [first | rest] ->
        name = module_name(first)
        [Map.get(env.aliases, name, name) | Enum.map(rest, &module_name/1)] |> Enum.join(".")

      [] ->
        nil
    end
  end

  @doc false
  def resolve_module({:__aliases__, _, parts}, env), do: alias_full(parts, env)
  def resolve_module({:__MODULE__, _, nil}, env), do: env.module
  def resolve_module(name, _env) when is_atom(name), do: Atom.to_string(name)
  def resolve_module(_other, _env), do: "?"
end
