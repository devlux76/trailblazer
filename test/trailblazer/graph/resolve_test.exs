defmodule Trailblazer.Graph.ResolveTest do
  use ExUnit.Case, async: false
  alias Trailblazer.{Store, Files}
  alias Trailblazer.Graph.Resolve

  setup do
    {:ok, repo} = Store.add_repo("/tmp/resolve-#{System.unique_integer([:positive])}")
    %{repo: repo}
  end

  test "fixture calls, duplicate names, imports, containment and stale citations", %{repo: repo} do
    root = Path.expand("../../fixtures/mini", __DIR__)
    for f <- Files.list(root), do: put(repo, f.path, f.lang, File.read!(Path.join(root, f.path)))
    es = Resolve.edges(repo)
    run = one(repo, "Mini.App.run/1")
    puts = Store.nodes_by_qualified(repo, "Mini.Store.put/2")
    assert length(puts) == 2

    assert Enum.sort(Enum.map(calls(es, run.id), &{&1.to_id, &1.uncertain})) ==
             Enum.sort(Enum.map(puts, &{&1.id, true}))

    render = one(repo, "renderList")
    save = one(repo, "saveHikes")
    assert [%{to_id: id, uncertain: false}] = calls(es, render.id)
    assert id == save.id
    main = one(repo, "main")
    assert [%{to_id: load, uncertain: false}] = calls(es, main.id)
    assert load == one(repo, "load").id

    assert Enum.any?(
             es,
             &(&1.from_id in Enum.map(puts, fn n -> n.id end) and &1.kind == "implements" and
                 &1.to_id == one(repo, "docs/design.md#2").id)
           )

    assert [%{target: "docs/design.md#9"}] = Resolve.stale_citations(repo)
    assert :ok = Store.put_edges(repo, Resolve.edges(repo))
  end

  test "external and escaping specs never fall back to a local homonym; ambiguity stays uncertain",
       %{repo: repo} do
    put(
      repo,
      "a.ts",
      :typescript,
      "import {read} from 'os'; import {f} from '../../escape'; export function run(){read(); f();}"
    )

    put(repo, "local.ts", :typescript, "export function read(){}\nexport function f(){}")
    assert calls(Resolve.edges(repo), one(repo, "run").id) == []

    put(
      repo,
      "m.ex",
      :elixir,
      "defmodule M do\n import Foo\n import Missing\n def run, do: f()\nend"
    )

    put(repo, "foo.ex", :elixir, "defmodule Foo do\n def f, do: :ok\nend")
    assert [%{uncertain: true}] = calls(Resolve.edges(repo), one(repo, "M.run/0").id)
  end

  test "local imports, default export, namespace, barrel and python relative modules", %{
    repo: repo
  } do
    put(
      repo,
      "web/save.ts",
      :typescript,
      "export default function save(){}\nexport function read(){}"
    )

    put(repo, "web/barrel/index.ts", :typescript, "export {read} from '../save.js';")

    put(
      repo,
      "web/app.ts",
      :typescript,
      "import save from './save.js'; import * as S from './save'; import {read} from './barrel'; export function run(){\n save();\n S.read();\n read();\n}"
    )

    assert Enum.sort(Enum.map(calls(Resolve.edges(repo), one(repo, "run").id), & &1.to_id)) ==
             Enum.sort([one(repo, "save").id, one(repo, "read").id, one(repo, "read").id])

    put(repo, "pkg/util.py", :python, "def read():\n pass\n")
    put(repo, "pkg/sub/a.py", :python, "from ..util import read\ndef main():\n read()\n")
    assert [%{to_id: id, uncertain: false}] = calls(Resolve.edges(repo), one(repo, "main").id)
    assert id == Enum.find(Store.nodes_by_qualified(repo, "read"), &(&1.path == "pkg/util.py")).id
  end

  test "nil source stays unresolved, contains is file local, caps are stable, other repos excluded",
       %{repo: repo} do
    put(repo, "a#b.ts", :typescript, "class C { f(){} }\nfunction run(){f();}")
    put(repo, "other.ts", :typescript, "class C { f(){} }")
    {:ok, other} = Store.add_repo("/tmp/other-#{repo}")
    put(other, "a.ts", :typescript, "function f(){}")
    for i <- 1..10, do: put(repo, "#{i}.ts", :typescript, "function f(){}")
    es = Resolve.edges(repo)
    assert length(calls(es, one(repo, "run").id)) == 8
    assert Enum.all?(calls(es, one(repo, "run").id), & &1.uncertain)
    assert es == Resolve.edges(repo)

    for e <- Enum.filter(es, &(&1.kind == "contains")) do
      assert Store.node(e.from_id).path == Store.node(e.to_id).path
    end

    assert Enum.all?(es, &(is_integer(&1.from_id) and is_integer(&1.to_id)))
    Store.delete_file(repo, "1.ts")
    assert length(calls(Resolve.edges(repo), one(repo, "run").id)) == 8
    assert Enum.any?(Store.refs(repo), &(&1.target == "f"))
  end

  test "empty repos and circular reexports terminate", %{repo: repo} do
    assert Resolve.edges(repo) == []
    assert Resolve.stale_citations(repo) == []
    put(repo, "a.ts", :typescript, "export {f} from './b'; export function run(){ f(); }")
    put(repo, "b.ts", :typescript, "export {f} from './a';")
    assert Resolve.edges(repo) == []
  end

  test "bad resolver boundary shapes preserve the previous graph and Store process", %{repo: repo} do
    put(repo, "a.ex", :elixir, "defmodule A do; def f, do: f(); end")
    es = Resolve.edges(repo)
    assert :ok = Store.put_edges(repo, es)
    pid = Process.whereis(Store)
    [node | _] = Store.nodes_by_qualified(repo, "A.f/0")

    for bad <- [
          %{from_id: nil, to_id: node.id, kind: "calls", uncertain: false},
          %{from_id: node.id, to_id: node.id, kind: "calls", uncertain: "false"},
          %{},
          nil
        ] do
      assert {:error, {:bad_edge, ^bad}} = Store.put_edges(repo, [bad])
      assert Store.edges_from(node.id) != []
    end

    bad = %{from_key: node.key, kind: "calls", target: "A.f", ambiguous: "false"}

    assert {:error, {:bad_ref, ^bad}} =
             Store.replace_file(repo, "a.ex", %{hash: "bad", nodes: [], refs: [bad]})

    assert Process.whereis(Store) == pid
    assert Store.node(node.id)
  end

  test "namespaces keep file identity despite local homonyms and external namespaces", %{
    repo: repo
  } do
    put(repo, "web/io.ts", :typescript, "export function read(){}")
    put(repo, "web/other.ts", :typescript, "export function read(){}")

    put(
      repo,
      "web/app.ts",
      :typescript,
      "import * as IO from './io'; import * as OS from 'os'; function run(){\n IO.read();\n OS.read();\n}"
    )

    assert [%{to_id: id, uncertain: false}] = calls(Resolve.edges(repo), one(repo, "run").id)
    assert id == hd(Store.nodes_in_file(repo, "web/io.ts")).id
    put(repo, "pkg/util.py", :python, "def read():\n pass\n")
    put(repo, "pkg/a.py", :python, "from . import util\ndef main():\n util.read()\n")
    assert [%{to_id: id, uncertain: false}] = calls(Resolve.edges(repo), one(repo, "main").id)
    assert id == hd(Store.nodes_in_file(repo, "pkg/util.py")).id
  end

  test "Python scripts choose a sibling module before the repository-root homonym", %{repo: repo} do
    put(repo, "util.py", :python, "def load():\n pass\n")
    put(repo, "tools/util.py", :python, "def load():\n pass\n")
    put(repo, "tools/run.py", :python, "from util import load\ndef main():\n load()\n")
    [edge] = calls(Resolve.edges(repo), one(repo, "main").id)
    assert Store.node(edge.to_id).path == "tools/util.py"
    assert not edge.uncertain
  end

  test "short doc citations prefer exact paths then component suffixes, including ambiguity", %{
    repo: repo
  } do
    put(repo, "nested/docs/design.md", :markdown, "## 2 Storage\n")
    put(repo, "m.ex", :elixir, "defmodule M do\n # docs/design.md §2\nend")
    [edge] = Enum.filter(Resolve.edges(repo), &(&1.kind == "implements"))
    assert Store.node(edge.to_id).path == "nested/docs/design.md"
    assert not edge.uncertain
    assert Resolve.stale_citations(repo) == []
    put(repo, "other/docs/design.md", :markdown, "## 2 Storage\n")
    es = Enum.filter(Resolve.edges(repo), &(&1.kind == "implements"))
    assert length(es) == 2
    assert Enum.all?(es, & &1.uncertain)
    put(repo, "docs/design.md", :markdown, "## 2 Storage\n")
    [edge] = Enum.filter(Resolve.edges(repo), &(&1.kind == "implements"))
    assert Store.node(edge.to_id).path == "docs/design.md"
    assert not edge.uncertain
  end

  test "bare citation filenames match a complete path component", %{repo: repo} do
    put(repo, "specs/mydesign.md", :markdown, "## 2 Storage\n")
    {:ok, p} = Trailblazer.Parse.Elixir.parse("m.ex", "defmodule M do; end")

    refs = [
      %{
        from_key: hd(p.nodes).key,
        kind: "implements",
        target: "design.md#2",
        arity: nil,
        line: 1,
        ambiguous: false
      }
    ]

    :ok = Store.replace_file(repo, "m.ex", %{hash: "h", nodes: p.nodes, refs: refs})
    assert [%{target: "design.md#2"}] = Resolve.stale_citations(repo)
    put(repo, "specs/design.md", :markdown, "## 2 Storage\n")
    [edge] = Enum.filter(Resolve.edges(repo), &(&1.kind == "implements"))
    assert Store.node(edge.to_id).path == "specs/design.md"
    assert not edge.uncertain
    assert Resolve.stale_citations(repo) == []
  end

  defp calls(es, id), do: Enum.filter(es, &(&1.from_id == id and &1.kind == "calls"))
  defp one(repo, q), do: Store.nodes_by_qualified(repo, q) |> hd()

  defp put(repo, path, lang, source) do
    {:ok, p} =
      case lang do
        :elixir -> Trailblazer.Parse.Elixir.parse(path, source)
        :markdown -> Trailblazer.Parse.Markdown.parse(path, source)
        _ -> Trailblazer.Parse.TreeSitter.parse(path, lang, source)
      end

    refs = p.refs ++ Trailblazer.Parse.Citations.scan(path, source, p.nodes)
    Store.replace_file(repo, path, %{hash: "hash", nodes: p.nodes, refs: refs})
  end
end
