defmodule Trailblazer.Parse.Elixir do
  @moduledoc """
  Elixir's own parser, read as definitions and references.

  Elixir is exact, so the names in the references are settled here rather than
  left to Task 6: the module stack, the alias table and the import table in
  force at each point decide what `Bar.put(x, y)` means. What the source does
  not settle — a local call whose function is not in the file, and which no
  import admits — is still emitted, against the module it is written in, so the
  resolver can mark it uncertain rather than lose it. When several imports
  admit the same name, the reference carries every candidate it has, in the
  order the source wrote them, and the resolver decides between them.

  The tables in force are lexical: an `alias` or an `import` written inside a
  function belongs to that function, and a nested module inherits what the
  module around it had already said.

  Definitions are modules, functions, macros, types and test cases. References
  are the calls, the captures, the directives (`alias`, `import`, `use`,
  `require`), each module's `contains` of what it declares, and the `tests` of
  what a test case exercises.
  """

  alias Trailblazer.Parse.Elixir.{Defaults, Env, Heads, Names, Records}

  @kinds %{
    def: "function",
    defp: "function",
    defdelegate: "function",
    defmacro: "macro",
    defguard: "macro"
  }

  @type_attrs ~w(type typep opaque)a

  # The forms that are Elixir's own machinery rather than a call to something
  # in the code. Their arguments are still walked, because they hold calls.
  @not_calls MapSet.new(
               ~w(+ - * / ++ -- +++ --- // <<< >>> && || === !== == != < > <= >= =~ !
                 |> << <> .. :: in not and or = ^ & % <<>> | fn -> when [] //
                 __block__ __aliases__ @ quote unquote unquote_splicing)a ++
                 [:{}, :%{}, :%]
             )
  @literals ~w(__MODULE__ __ENV__ __DIR__ __STACKTRACE__ __CALLER__)a

  # The macros a guard may call, which live in Kernel whatever the module is.
  @kernel ~w(is_alias is_atom is_binary is_bitstring is_boolean is_float is_function
             is_integer is_list is_map is_nil is_number is_pid is_port is_reference
             is_struct is_tuple is_map_key)a

  @spec parse(Path.t(), binary()) ::
          {:ok, %{nodes: [map()], refs: [map()]}} | {:error, {integer(), binary()}}
  def parse(path, source) do
    case quoted(path, source) do
      {:ok, ast} ->
        env = Env.env(path, source)
        {_env, acc} = expr(ast, env, Records.new_acc())
        acc = resolve_pending(env, acc, nil)

        {:ok,
         %{
           # Source order, by where each definition starts, across every kind.
           # The sort is stable, so heads that default arguments add stay
           # before the head the source spells out (see add_clauses).
           nodes:
             acc.nodes
             |> Enum.reverse()
             |> Enum.sort_by(& &1.at)
             |> Enum.map(&Map.delete(&1, :at)),
           refs: acc.refs |> Enum.sort_by(& &1.seq) |> Enum.map(&Map.delete(&1, :seq))
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  ## Parsing

  defp quoted(path, source) do
    source =
      case source do
        <<0xEF, 0xBB, 0xBF, rest::binary>> -> rest
        _other -> source
      end

    case Code.string_to_quoted(source, columns: true, token_metadata: true, file: path) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {meta, message, _token}} when is_list(meta) ->
        {:error, {meta[:line] || 1, message}}

      {:error, message} ->
        {:error, {1, message}}
    end
  rescue
    exception -> {:error, {exception_line(exception), Exception.message(exception)}}
  end

  defp exception_line(%{line: line}) when is_integer(line), do: line
  defp exception_line(_other), do: 1

  ## Walking

  # A module: what it declares, and the environment its body is read in.

  defp expr({:defmodule, meta, [name_ast, body]}, env, acc) do
    name = Names.module_name(name_ast)
    qualified = Env.qualify(env.module, name)
    key = Env.node_key(env, "module", qualified)

    acc =
      acc
      |> Records.add_node(
        Records.node(env, "module", name, qualified, key, meta, "defmodule #{name}")
      )
      |> Records.add_contains(env, qualified, meta)

    inner = %{
      env
      | module: qualified,
        module_key: key,
        # what an inner module aliases or imports of its own is its own; what the
        # module around it had said before it carries in
        aliases: Map.new(env.aliases),
        imports: env.imports,
        defs: MapSet.new(),
        clauses: %{},
        ex_unit: false,
        current: nil,
        test: nil,
        describe: [],
        defaults: %{}
    }

    {inner, acc} = walk_all(body, inner, acc)
    acc = Records.add_clauses(inner, acc)
    acc = resolve_pending(inner, acc, qualified)

    # `defmodule Child` inside M leaves Child bound to M.Child in the rest of M,
    # the way it does when Elixir reads it.
    {put_child(env, name, qualified), acc}
  end

  # A definition. One node per arity; the body belongs to the node of the
  # arity the source spells out, which is the largest.

  defp expr({form, meta, args}, env, acc)
       when form in [:def, :defp, :defmacro, :defdelegate, :defguard] and is_list(args) do
    {head, body} = Heads.def_head_and_body(args)
    name = Heads.def_name(head)
    parameters = Heads.def_args(head)
    kind = Map.fetch!(@kinds, form)
    qualified = Env.qualify(env.module, "#{name}")

    env =
      Enum.reduce(Heads.arities(parameters), env, fn arity, env ->
        clause = %{
          kind: kind,
          name: "#{name}",
          qualified: "#{qualified}/#{arity}",
          key: Env.node_key(env, kind, "#{qualified}/#{arity}"),
          first: Env.line_of(meta),
          last: Env.end_line_of(meta),
          at: {Env.line_of(meta), Env.column_of(meta)},
          arity: arity,
          signature: Heads.signature(head)
        }

        env = %{
          env
          | defs: MapSet.put(env.defs, {name, arity}),
            clauses: Map.update(env.clauses, clause.key, clause, &Records.span(&1, clause))
        }

        env
      end)

    key = Env.node_key(env, kind, "#{qualified}/#{List.last(Heads.arities(parameters))}")

    # A directive written inside a function is that function's: the sibling
    # defined after it reads the module's table, not this one's.
    inside = %{
      env
      | current: key,
        aliases: Map.new(env.aliases),
        defaults: Defaults.bindings(body, env, parameters)
    }

    {_inside, acc} = walk_all(body ++ Heads.defaults(parameters), inside, acc)
    {%{env | current: nil}, acc}
  end

  defp expr({:@, meta, [{attr, _, args}]}, env, acc) when attr in @type_attrs do
    {name, _arity} = Heads.type_name(args)
    qualified = Env.qualify(env.module, name)
    key = Env.node_key(env, "type", qualified)

    acc =
      acc
      |> Records.add_node(
        Records.node(env, "type", name, qualified, key, meta, "@#{attr} #{name}")
      )
      |> Records.add_contains(env, qualified, meta)

    {env, acc}
  end

  # An ExUnit test case, in a module that uses ExUnit.Case.

  defp expr({:describe, _meta, [name | body]}, %{ex_unit: true} = env, acc)
       when is_binary(name) do
    env = %{env | describe: env.describe ++ [name]}
    {env, acc} = walk_all(body, env, acc)
    {%{env | describe: List.delete_at(env.describe, -1)}, acc}
  end

  defp expr({:test, meta, [name | body]}, %{ex_unit: true} = env, acc) when is_binary(name) do
    name = (env.describe ++ [name]) |> Enum.join(" ")
    qualified = Env.qualify(env.module, name)
    key = Env.node_key(env, "test", qualified)

    acc =
      acc
      |> Records.add_node(
        Records.node(env, "test", name, qualified, key, meta, "test #{inspect(name)}")
      )
      |> Records.add_contains(env, qualified, meta)

    {env, acc} = walk_all(body, %{env | test: key}, acc)
    {%{env | test: nil}, acc}
  end

  # The directives. `alias` renames a module for the rest of the module's body;
  # `import` also makes its functions callable unqualified; `use` and `require`
  # only make macros available, so they are recorded and not resolved against.
  defp expr({:alias, meta, [target | opts]}, env, acc) do
    acc = Records.add_refs(acc, env, "aliases", Names.names_of(target, opts, env), meta)
    {Names.put_aliases(env, Names.names_of(target, opts, env)), acc}
  end

  defp expr({:import, meta, [target | opts]}, env, acc) do
    names = Names.names_of(target, [], env)
    acc = Records.add_refs(acc, env, "imports", names, meta)
    filter = Names.import_filter(opts)

    imports =
      Enum.map(names, fn {_name, full} ->
        %{module: full, only: filter.only, except: filter.except}
      end)

    {%{env | imports: env.imports ++ imports}, acc}
  end

  defp expr({:use, meta, [target | _opts]}, env, acc) do
    acc = Records.add_refs(acc, env, "uses", Names.names_of(target, [], env), meta)

    env =
      if "ExUnit.Case" in Enum.map(Names.names_of(target, [], env), &elem(&1, 1)),
        do: %{env | ex_unit: true},
        else: env

    {env, acc}
  end

  defp expr({:require, meta, [target | _opts]}, env, acc) do
    acc = Records.add_refs(acc, env, "uses", Names.names_of(target, [], env), meta)
    {env, acc}
  end

  # A remote call.

  defp expr({{:., _, [module_ast, function]}, meta, args}, env, acc) when is_atom(function) do
    args = args || []
    acc = remote_call(acc, env, module_ast, function, args, meta)

    # the arguments hold calls of their own, written in the caller's scope
    walk_all(args, env, acc)
  end

  # A capture: `&Mod.f/2`, `&f/1`, or `&1` and friends, which are not calls.

  defp expr({:&, meta, [{:/, _, [target, arity]}]}, env, acc) when is_integer(arity) do
    {env, capture(acc, env, meta, target, arity)}
  end

  defp expr({:&, _meta, args}, env, acc) do
    walk_all(args, env, acc)
  end

  # A pipe: the left side is the first argument of the call on the right.

  defp expr({:|>, meta, [left, right]}, env, acc) do
    {env, acc} = expr(left, env, acc)
    {env, piped(acc, env, meta, right)}
  end

  defp expr({:__aliases__, _meta, _parts}, env, acc), do: {env, acc}
  defp expr({name, _meta, _args}, env, acc) when name in @literals, do: {env, acc}
  defp expr({:__block__, _meta, args}, env, acc), do: walk_all(args, env, acc)
  defp expr({:when, _meta, args}, env, acc), do: walk_all(args, env, acc)
  defp expr({:"::", _meta, args}, env, acc), do: walk_all(tl(args), env, acc)
  defp expr({:quote, _meta, _args}, env, acc), do: {env, acc}
  defp expr({:unquote, _meta, args}, env, acc), do: walk_all(args, env, acc)
  defp expr({:unquote_splicing, _meta, args}, env, acc), do: walk_all(args, env, acc)
  defp expr({:->, _meta, [_head | body]}, env, acc), do: walk_all(body, env, acc)
  # a keyword list entry: [do: ..., when: ...] reaches here as a pair
  defp expr({key, value}, env, acc) when is_atom(key), do: walk_all([value], env, acc)

  # A local call, settled once the module's definitions have all been read.

  defp expr({name, meta, args}, env, acc) when is_atom(name) and is_list(args) do
    if MapSet.member?(@not_calls, name) do
      walk_all(args, env, acc)
    else
      acc = pending(acc, env, "calls", name, length(args), meta)
      walk_all(args, env, acc)
    end
  end

  defp expr({_form, _meta, args}, env, acc) when is_list(args), do: walk_all(args, env, acc)
  defp expr(list, env, acc) when is_list(list), do: walk_all(list, env, acc)
  defp expr(_other, env, acc), do: {env, acc}

  defp walk_all(list, env, acc) when is_list(list) do
    Enum.reduce(list, {env, acc}, fn item, {env, acc} -> expr(item, env, acc) end)
  end

  defp walk_all(other, env, acc), do: expr(other, env, acc)

  # `defmodule Child` inside M leaves Child bound to M.Child in the rest of M,
  # the way it does when Elixir reads it.
  defp put_child(env, name, qualified) do
    short = name |> String.split(".") |> List.last()
    %{env | aliases: Map.put(env.aliases, short, qualified)}
  end

  ## Calls

  # A call through a variable the function bound to a default module is a call to
  # that module, guessed at and marked so: `workspace.close(x)` after
  # `workspace = mod(st, :workspace, Workspace)` reads as Workspace.close.
  defp remote_call(acc, env, module_ast, function, args, meta) do
    case default_module(module_ast, env) do
      {:ok, module} ->
        Records.add_guessed_ref(
          acc,
          env,
          "calls",
          "#{module}.#{function}",
          length(args),
          meta,
          "default_module"
        )

      :error ->
        target = "#{Names.resolve_module(module_ast, env)}.#{function}"
        Records.add_ref(acc, env, "calls", target, length(args), meta)
    end
  end

  defp default_module({var, _meta, ctx}, env) when is_atom(var) and is_atom(ctx),
    do: Map.fetch(env.defaults, var)

  defp default_module(_module_ast, _env), do: :error

  defp piped(acc, env, meta, right) do
    case right do
      {{:., _, [module_ast, function]}, _, args} when is_atom(function) ->
        args = args || []
        target = "#{Names.resolve_module(module_ast, env)}.#{function}"
        acc = Records.add_ref(acc, env, "calls", target, length(args) + 1, meta)
        {_, acc} = walk_all(args, env, acc)
        acc

      {name, _, args} when is_atom(name) and is_list(args) ->
        acc = pending(acc, env, "calls", name, length(args) + 1, meta)
        {_, acc} = walk_all(args, env, acc)
        acc

      other ->
        {_, acc} = walk_all([other], env, acc)
        acc
    end
  end

  defp capture(acc, env, meta, target, arity) do
    case target do
      {{:., _, [module_ast, function]}, _, _args} when is_atom(function) ->
        Records.add_ref(
          acc,
          env,
          "references",
          "#{Names.resolve_module(module_ast, env)}.#{function}",
          arity,
          meta
        )

      {name, _, nil} when is_atom(name) ->
        pending(acc, env, "references", name, arity, meta)

      other ->
        {_, acc} = walk_all([other], env, acc)
        acc
    end
  end

  # A local call is settled at the end of the module it was written in, because
  # a function may be defined after the place that calls it. Only that one
  # question is left open: everything else — who makes the call, of what kind,
  # under which imports — is written down here, where the source settles it.
  defp pending(acc, env, kind, name, arity, meta) do
    ref = %{
      module: env.module,
      from_key: Records.from_of(env),
      kind: Records.kind_in(env, kind),
      name: name,
      arity: arity,
      imports: env.imports,
      line: Env.line_of(meta),
      seq: acc.seq
    }

    %{acc | pending: [ref | acc.pending], seq: acc.seq + 1}
  end

  defp resolve_pending(env, acc, module) do
    {mine, theirs} = Enum.split_with(acc.pending, &(&1.module == module))
    acc = %{acc | pending: theirs}

    Enum.reduce(mine, acc, fn ref, acc ->
      target = local_target(env, ref.name, ref.arity, ref.imports)
      targets = List.wrap(target)

      Enum.reduce(Enum.reverse(targets), acc, fn candidate, acc ->
        Records.put_ref(
          acc,
          ref.seq,
          ref.from_key,
          ref.kind,
          candidate,
          ref.arity,
          ref.line,
          length(targets) > 1
        )
      end)
    end)
  end

  defp local_target(env, name, arity, imports) do
    cond do
      name in @kernel -> "Kernel.#{name}"
      MapSet.member?(env.defs, {name, arity}) -> Env.qualify(env.module, "#{name}")
      true -> imported_target(imports, env, name, arity)
    end
  end

  # An import admits a name and arity unless one of its filters says otherwise.
  # One candidate settles the call; several leave it open, and the resolver is
  # the one that marks the edges uncertain.
  defp imported_target(imports, env, name, arity) do
    case Enum.filter(imports, &admits?(&1, name, arity)) do
      [] -> Env.qualify(env.module, "#{name}")
      [only_one] -> "#{only_one.module}.#{name}"
      candidates -> Enum.map(candidates, &"#{&1.module}.#{name}")
    end
  end

  defp admits?(import, name, arity) do
    only = import.only
    except = import.except

    (is_nil(only) or entry?(only, name, arity)) and not entry?(except, name, arity)
  end

  defp entry?(entries, name, arity) do
    Enum.any?(entries, fn
      {^name, nil} -> true
      {^name, ^arity} -> true
      _other -> false
    end)
  end
end
