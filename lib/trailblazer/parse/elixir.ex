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
        env = env(path, source)
        {_env, acc} = expr(ast, env, new_acc())
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
    name = module_name(name_ast)
    qualified = qualify(env.module, name)
    key = node_key(env, "module", qualified)

    acc =
      acc
      |> add_node(node(env, "module", name, qualified, key, meta, "defmodule #{name}"))
      |> add_contains(env, qualified, meta)

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
        describe: []
    }

    {inner, acc} = walk_all(body, inner, acc)
    acc = add_clauses(inner, acc)
    acc = resolve_pending(inner, acc, qualified)

    # `defmodule Child` inside M leaves Child bound to M.Child in the rest of M,
    # the way it does when Elixir reads it.
    {put_child(env, name, qualified), acc}
  end

  # A definition. One node per arity; the body belongs to the node of the
  # arity the source spells out, which is the largest.

  defp expr({form, meta, args}, env, acc)
       when form in [:def, :defp, :defmacro, :defdelegate, :defguard] and is_list(args) do
    {head, body} = def_head_and_body(args)
    name = def_name(head)
    parameters = def_args(head)
    kind = Map.fetch!(@kinds, form)
    qualified = qualify(env.module, "#{name}")

    env =
      Enum.reduce(arities(parameters), env, fn arity, env ->
        clause = %{
          kind: kind,
          name: "#{name}",
          qualified: "#{qualified}/#{arity}",
          key: node_key(env, kind, "#{qualified}/#{arity}"),
          first: line_of(meta),
          last: end_line_of(meta),
          at: {line_of(meta), column_of(meta)},
          arity: arity,
          signature: signature(head)
        }

        env = %{
          env
          | defs: MapSet.put(env.defs, {name, arity}),
            clauses: Map.update(env.clauses, clause.key, clause, &span(&1, clause))
        }

        env
      end)

    key = node_key(env, kind, "#{qualified}/#{List.last(arities(parameters))}")

    # A directive written inside a function is that function's: the sibling
    # defined after it reads the module's table, not this one's.
    inside = %{env | current: key, aliases: Map.new(env.aliases)}

    {_inside, acc} = walk_all(body ++ defaults(parameters), inside, acc)
    {%{env | current: nil}, acc}
  end

  defp expr({:@, meta, [{attr, _, args}]}, env, acc) when attr in @type_attrs do
    {name, _arity} = type_name(args)
    qualified = qualify(env.module, name)
    key = node_key(env, "type", qualified)

    acc =
      acc
      |> add_node(node(env, "type", name, qualified, key, meta, "@#{attr} #{name}"))
      |> add_contains(env, qualified, meta)

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
    qualified = qualify(env.module, name)
    key = node_key(env, "test", qualified)

    acc =
      acc
      |> add_node(node(env, "test", name, qualified, key, meta, "test #{inspect(name)}"))
      |> add_contains(env, qualified, meta)

    {env, acc} = walk_all(body, %{env | test: key}, acc)
    {%{env | test: nil}, acc}
  end

  # The directives. `alias` renames a module for the rest of the module's body;
  # `import` also makes its functions callable unqualified; `use` and `require`
  # only make macros available, so they are recorded and not resolved against.
  defp expr({:alias, meta, [target | opts]}, env, acc) do
    acc = add_refs(acc, env, "aliases", names_of(target, opts, env), meta)
    {put_aliases(env, names_of(target, opts, env)), acc}
  end

  defp expr({:import, meta, [target | opts]}, env, acc) do
    names = names_of(target, [], env)
    acc = add_refs(acc, env, "imports", names, meta)
    filter = import_filter(opts)

    imports =
      Enum.map(names, fn {_name, full} ->
        %{module: full, only: filter.only, except: filter.except}
      end)

    {%{env | imports: env.imports ++ imports}, acc}
  end

  defp expr({:use, meta, [target | _opts]}, env, acc) do
    acc = add_refs(acc, env, "uses", names_of(target, [], env), meta)

    env =
      if "ExUnit.Case" in Enum.map(names_of(target, [], env), &elem(&1, 1)),
        do: %{env | ex_unit: true},
        else: env

    {env, acc}
  end

  defp expr({:require, meta, [target | _opts]}, env, acc) do
    acc = add_refs(acc, env, "uses", names_of(target, [], env), meta)
    {env, acc}
  end

  # A remote call.

  defp expr({{:., _, [module_ast, function]}, meta, args}, env, acc) when is_atom(function) do
    args = args || []
    target = "#{resolve_module(module_ast, env)}.#{function}"
    acc = add_ref(acc, env, "calls", target, length(args), meta)

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

  defp piped(acc, env, meta, right) do
    case right do
      {{:., _, [module_ast, function]}, _, args} when is_atom(function) ->
        args = args || []
        target = "#{resolve_module(module_ast, env)}.#{function}"
        acc = add_ref(acc, env, "calls", target, length(args) + 1, meta)
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
        add_ref(
          acc,
          env,
          "references",
          "#{resolve_module(module_ast, env)}.#{function}",
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
      from_key: from_of(env),
      kind: kind_in(env, kind),
      name: name,
      arity: arity,
      imports: env.imports,
      line: line_of(meta),
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
        put_ref(
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
      MapSet.member?(env.defs, {name, arity}) -> qualify(env.module, "#{name}")
      true -> imported_target(imports, env, name, arity)
    end
  end

  # An import admits a name and arity unless one of its filters says otherwise.
  # One candidate settles the call; several leave it open, and the resolver is
  # the one that marks the edges uncertain.
  defp imported_target(imports, env, name, arity) do
    case Enum.filter(imports, &admits?(&1, name, arity)) do
      [] -> qualify(env.module, "#{name}")
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

  ## Aliases and imports

  # The names a directive binds: `alias Foo.Bar` binds Bar, `alias Foo.Bar,
  # as: B` binds B, `alias Foo.{A, B}` binds both — and `alias Foo.Bar.{A, B}`
  # binds both under the whole prefix.
  defp names_of(target, opts, env) do
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

  defp put_aliases(env, names) do
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
  defp import_filter(opts) do
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

  defp module_name({:__aliases__, _, parts}), do: Enum.map_join(parts, ".", &module_name/1)
  defp module_name(name) when is_atom(name), do: Atom.to_string(name)
  defp module_name(name) when is_binary(name), do: name
  defp module_name(_other), do: "?"

  # Elixir settles a module name on its first segment: the rest is appended.
  # `__MODULE__` stands for the module being written in, so a name written
  # under it is nested in that module.
  defp alias_full(parts, env) do
    case parts do
      [{:__MODULE__, _, nil} | rest] ->
        case Enum.map_join(rest, ".", &module_name/1) do
          "" -> env.module
          nested -> qualify(env.module, nested)
        end

      [first | rest] ->
        name = module_name(first)
        [Map.get(env.aliases, name, name) | Enum.map(rest, &module_name/1)] |> Enum.join(".")

      [] ->
        nil
    end
  end

  defp resolve_module({:__aliases__, _, parts}, env), do: alias_full(parts, env)
  defp resolve_module({:__MODULE__, _, nil}, env), do: env.module
  defp resolve_module(name, _env) when is_atom(name), do: Atom.to_string(name)
  defp resolve_module(_other, _env), do: "?"

  ## Definition heads

  defp def_head_and_body(args) do
    case args do
      [{:when, _, [head | rest]} | body] -> {head, body ++ rest}
      [head | body] -> {head, body}
      [] -> {nil, []}
    end
  end

  defp def_name({name, _meta, _args}) when is_atom(name), do: name
  defp def_name(_other), do: :undefined

  defp def_args({_name, _meta, args}) when is_list(args), do: args
  defp def_args(_other), do: []

  # `def g(a, b \\ 1)` is both g/1 and g/2.
  defp arities(parameters) do
    defaults = Enum.count(parameters, &match?({:\\, _, [_var, _default]}, &1))
    declared = length(parameters)
    smallest = declared - defaults

    if smallest >= declared, do: [declared], else: Enum.to_list(smallest..declared)
  end

  defp defaults(parameters) do
    for {:\\, _, [_var, default]} <- parameters, do: default
  end

  defp type_name([{:"::", _, [head | _]} | _]), do: head_name(head)
  defp type_name([head | _]), do: head_name(head)
  defp type_name(_other), do: {"unknown", 0}

  defp head_name({name, _meta, args}) when is_atom(name) do
    {Atom.to_string(name), if(is_list(args), do: length(args), else: 0)}
  end

  defp head_name(_other), do: {"unknown", 0}

  ## Accumulating

  defp new_acc, do: %{nodes: [], refs: [], pending: [], seq: 0}

  defp add_node(acc, node), do: %{acc | nodes: [node | acc.nodes]}

  defp add_ref(acc, env, kind, target, arity, meta) do
    put_ref(acc, acc.seq, from_of(env), kind_in(env, kind), target, arity, line_of(meta))
  end

  # Every reference carries the number the walk gave it, so that the ones
  # settled at the end of a module keep their place among the ones settled as
  # they were read.
  defp put_ref(acc, seq, from_key, kind, target, arity, line, ambiguous \\ false) do
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
  defp from_of(env), do: env.test || env.current || env.module_key

  defp kind_in(%{test: nil}, kind), do: kind
  defp kind_in(_env, "calls"), do: "tests"
  defp kind_in(_env, kind), do: kind

  defp add_refs(acc, env, kind, names, meta) do
    Enum.reduce(names, acc, fn {_name, full}, acc ->
      add_ref(acc, env, kind, full, nil, meta)
    end)
  end

  # A module holds what it declares.
  defp add_contains(acc, %{module_key: nil}, _qualified, _meta), do: acc

  defp add_contains(acc, env, qualified, meta) do
    add_ref(acc, %{env | test: nil, current: nil}, "contains", qualified, nil, meta)
  end

  # The clauses of one function are one definition: its range spans them all.
  defp span(clause, %{first: first, last: last, at: at}) do
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
  defp add_clauses(env, acc) do
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
      text_hash: text_hash(env, first, last)
    })
  end

  defp node(env, kind, name, qualified, key, meta, signature) do
    first = line_of(meta)
    last = end_line_of(meta)

    %{
      key: key,
      at: {first, column_of(meta)},
      lang: "elixir",
      kind: kind,
      name: name,
      qualified: qualified,
      path: env.path,
      start_line: first,
      end_line: last,
      signature: String.slice(signature, 0, 200),
      # one hash per line range: two clauses of one function share it
      text_hash: text_hash(env, first, last)
    }
  end

  defp numbered(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {line, number} -> {number, line} end)
    |> Map.new()
  end

  defp text_hash(env, first, last) do
    lines = for number <- first..max(last, first), do: Map.get(env.lines, number, "")

    lines
    |> Enum.map_join("\n", & &1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # A signature is one line: the head as the source writes it, with every run
  # of whitespace collapsed, so it can head a line of its own.
  defp signature(head) when is_tuple(head) do
    head
    |> Macro.to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp signature(_other), do: ""

  ## Environment

  defp env(path, source) do
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

  defp line_of(meta) when is_list(meta), do: Keyword.get(meta, :line, 1)
  defp line_of(_other), do: 1

  defp column_of(meta) when is_list(meta), do: Keyword.get(meta, :column, 0)
  defp column_of(_other), do: 0

  # Elixir's metadata gives the line an expression ends on only when it ends a
  # block; a one-line expression is ended by the end of its own line.
  defp end_line_of(meta) when is_list(meta) do
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

  defp end_line_of(_other), do: 1

  defp qualify(nil, name), do: name
  defp qualify(module, name), do: "#{module}.#{name}"

  defp node_key(env, kind, qualified), do: "elixir:#{kind}:#{env.path}##{qualified}"
end
