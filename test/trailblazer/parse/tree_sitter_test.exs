defmodule Trailblazer.Parse.TreeSitterTest do
  use ExUnit.Case, async: false

  alias Trailblazer.{Anomaly, Events}
  alias Trailblazer.Parse.TreeSitter

  @javascript """
  class Store {
    put(hike) {
      return hike;
    }
  }

  function saveHikes(hikes) {}
  """

  @typescript """
  import { saveHikes } from "./save";

  export function renderList(hikes: string[]): string {
    saveHikes(hikes);
    return hikes.join(", ");
  }
  """

  @python """
  from app.store import put

  def load():
      return put()
  """

  setup do
    # the pool publishes what each parser is doing (design §13.2 rule 3)
    Events.subscribe(:parse)
    :ok
  end

  test "a missing parser binary returns a release-safe error and the pool survives" do
    pool = Process.whereis(TreeSitter)
    close_parsers()

    path = Path.join(:code.priv_dir(:trailblazer), "ts_port")
    backup = path <> ".missing-test"
    File.rename!(path, backup)

    try do
      assert {:error, :parser_missing} = TreeSitter.parse("a.ts", :typescript, "function f(){}")
      assert Process.whereis(TreeSitter) == pool
    after
      File.rename!(backup, path)
    end

    assert {:ok, _} = TreeSitter.parse("a.ts", :typescript, "function f(){}")
    assert Process.whereis(TreeSitter) == pool
  end

  test "constructors own their calls and type annotations survive as references" do
    {:ok, parsed} =
      TreeSitter.parse(
        "camp.ts",
        :typescript,
        "class Camp {\n state: FireState;\n constructor(){\n  this.state = new FireState();\n  setup();\n }\n}\n"
      )

    assert Enum.any?(parsed.nodes, &(&1.qualified == "Camp.constructor"))

    assert Enum.any?(
             parsed.refs,
             &(&1.kind == "calls" and &1.target == "FireState" and
                 &1.from_key == "typescript:method:camp.ts#Camp.constructor")
           )

    assert Enum.any?(parsed.refs, &(&1.kind == "references" and &1.target == "FireState"))
  end

  test "a round trip through the Port gives the definitions and references" do
    assert {:ok, parsed} = TreeSitter.parse("web/app.js", :javascript, @javascript)

    assert ["Store", "Store.put", "saveHikes"] =
             Enum.map(parsed.nodes, & &1.qualified)

    assert [
             %{kind: "class", name: "Store", key: "javascript:class:web/app.js#Store"},
             %{kind: "method", name: "put", key: "javascript:method:web/app.js#Store.put"},
             %{kind: "function", name: "saveHikes"}
           ] = parsed.nodes
  end

  test "every node carries what the store keys it by" do
    assert {:ok, parsed} = TreeSitter.parse("web/app.js", :javascript, @javascript)
    [store | _] = parsed.nodes

    assert store.lang == "javascript"
    assert store.path == "web/app.js"
    assert store.start_line == 1
    assert store.end_line == 5
  end

  test "the signature is the definition's first line, and the hash its own lines" do
    source = "class Store {\n  put(hike) {\n    return hike;\n  }\n}\n"

    assert {:ok, parsed} = TreeSitter.parse("web/app.js", :javascript, source)
    [store | _] = parsed.nodes

    assert store.signature == "class Store {"
    assert store.text_hash == sha256("class Store {\n  put(hike) {\n    return hike;\n  }\n}")
  end

  test "a call inside a method comes from the method" do
    source = "class Store {\n  put(hike) {\n    return saveHikes(hike);\n  }\n}\n"

    assert {:ok, parsed} = TreeSitter.parse("web/app.js", :javascript, source)

    assert %{kind: "calls", target: "saveHikes", from_key: key} =
             Enum.find(parsed.refs, &(&1.kind == "calls"))

    assert key == "javascript:method:web/app.js#Store.put"
  end

  test "typescript imports carry the specifier and the names it brings in" do
    assert {:ok, parsed} = TreeSitter.parse("web/app.ts", :typescript, @typescript)

    assert %{kind: "imports", target: "./save", arity: nil, from_key: nil} =
             Enum.find(parsed.refs, &(&1.kind == "imports"))

    assert %{kind: "references", target: "./save#saveHikes", line: 1} =
             Enum.find(parsed.refs, &(&1.kind == "references"))
  end

  test "python imports carry the module and the names it brings in" do
    assert {:ok, parsed} = TreeSitter.parse("tools/index.py", :python, @python)

    assert ["load"] = Enum.map(parsed.nodes, & &1.qualified)

    assert %{kind: "imports", target: "app.store"} =
             Enum.find(parsed.refs, &(&1.kind == "imports"))

    assert %{kind: "references", target: "app.store#put"} =
             Enum.find(parsed.refs, &(&1.kind == "references"))
  end

  test "tsx is parsed as TypeScript with JSX" do
    source = "export function List(): JSX.Element {\n  return <div>hi</div>;\n}\n"

    assert {:ok, parsed} = TreeSitter.parse("web/app.tsx", :tsx, source)
    assert ["List"] = Enum.map(parsed.nodes, & &1.qualified)
  end

  test "a file that does not parse keeps what came before the error" do
    source = "function saveHikes() {}\n\nclass Broken {\n  put( {\n"

    assert {:ok, parsed} = TreeSitter.parse("web/app.js", :javascript, source)
    assert "saveHikes" in Enum.map(parsed.nodes, & &1.qualified)
  end

  test "a language the Port does not have is an error" do
    pool = Process.whereis(TreeSitter)

    for lang <- [:ruby, "javascript", nil, 42, [], %{}] do
      assert {:error, {:unknown_lang, ^lang}} = TreeSitter.parse("a.js", lang, "")
      assert Process.whereis(TreeSitter) == pool
    end

    assert {:ok, _} = TreeSitter.parse("a.js", :javascript, "function ok() {}")
  end

  test "invalid UTF-8 returns an error and leaves the shared parser usable" do
    pool = Process.whereis(TreeSitter)

    assert {:error, :invalid_encoding} =
             TreeSitter.parse("a.py", :python, <<35, 32, 0xE9>>)

    assert Process.whereis(TreeSitter) == pool
    assert Process.alive?(pool)

    assert {:ok, %{nodes: [%{qualified: "ok"}]}} =
             TreeSitter.parse("a.py", :python, "def ok():\n    pass\n")
  end

  test "through the Port: an aliased call, the caller of a call, and what a class holds" do
    source = """
    import { put as save } from "./store";
    class Store {
      put() { save(); }
    }
    done();
    """

    assert {:ok, %{refs: refs}} = TreeSitter.parse("web/app.js", :javascript, source)

    assert %{from_key: "javascript:method:web/app.js#Store.put", line: 3} =
             Enum.find(refs, &(&1.kind == "calls" and &1.target == "./store#put"))

    assert %{from_key: nil} = Enum.find(refs, &(&1.kind == "calls" and &1.target == "done"))

    assert %{from_key: "javascript:class:web/app.js#Store"} =
             Enum.find(refs, &(&1.kind == "contains" and &1.target == "Store.put"))

    refute Enum.any?(refs, &(&1.target == "./store#save"))
  end

  test "a parser killed while idle is replaced by the next call" do
    assert {:ok, _parsed} = TreeSitter.parse("web/a.js", :javascript, "const a = 1;\n")
    assert {:ok, _parsed} = TreeSitter.parse("web/b.js", :javascript, "const b = 2;\n")

    # one parser per worker, each its own OS process
    pids = TreeSitter.os_pids()
    assert length(pids) == 2
    for pid <- pids, do: System.cmd("kill", ["-9", "#{pid}"])

    # the OS processes go while nothing waits on them; the pool hears of both
    # and the next call opens new ones, so no file is the one told it is gone
    assert eventually(fn -> TreeSitter.os_pids() == [] end)

    assert {:ok, _parsed} = TreeSitter.parse("web/c.js", :javascript, "const c = 3;\n")
    assert_receive {:trailblazer_event, :parse, {:started, "web/c.js", _worker, fresh}}, 30_000
    refute fresh in pids
  end

  test "two files are parsed at the same time, each by a parser process of its own" do
    # the pool of parsers, `parse_workers` of them, two by default
    assert map_size(:sys.get_state(TreeSitter).workers) == 2

    a = Task.async(fn -> TreeSitter.parse("parallel/a.js", :javascript, held_javascript()) end)
    b = Task.async(fn -> TreeSitter.parse("parallel/b.js", :javascript, held_javascript()) end)

    assert_receive {:trailblazer_event, :parse, {:started, "parallel/a.js", worker_a, pid_a}},
                   60_000

    assert_receive {:trailblazer_event, :parse, {:started, "parallel/b.js", worker_b, pid_b}},
                   60_000

    # two files in flight means two workers, and two OS processes
    assert worker_a != worker_b
    assert is_integer(pid_a) and is_integer(pid_b)
    assert pid_a != pid_b

    # neither had finished when the second one started
    refute_receive {:trailblazer_event, :parse, {:ended, _, _, _}}, 0

    assert {:ok, _} = Task.await(a, 60_000)
    assert {:ok, _} = Task.await(b, 60_000)
  end

  test "a parser killed mid-file fails only its own file, and the queue goes on (J14)" do
    a = Task.async(fn -> TreeSitter.parse("crash/a.js", :javascript, held_javascript()) end)
    b = Task.async(fn -> TreeSitter.parse("crash/b.js", :javascript, held_javascript()) end)

    assert_receive {:trailblazer_event, :parse, {:started, "crash/a.js", _worker_a, pid_a}},
                   60_000

    assert_receive {:trailblazer_event, :parse, {:started, "crash/b.js", _worker_b, pid_b}},
                   60_000

    assert pid_a != pid_b

    # queued behind both: it runs as soon as one parser is free again
    c = Task.async(fn -> TreeSitter.parse("crash/c.js", :javascript, "const c = 1;\n") end)

    System.cmd("kill", ["-9", "#{pid_a}"])

    assert {:error, :parser_crashed} = Task.await(a, 60_000)
    assert {:ok, _} = Task.await(b, 60_000)
    assert {:ok, _} = Task.await(c, 60_000)

    # the pool replaced the parser that died and is whole again
    assert {:ok, _} = TreeSitter.parse("crash/d.js", :javascript, "const d = 2;\n")
    assert length(TreeSitter.os_pids()) == 2
    refute pid_a in TreeSitter.os_pids()
  end

  test "a parse that never answers is given up on by its backstop, and the anomaly is recorded" do
    source = held_javascript()

    with_env(:investigate_transport, :none, fn ->
      # a limit so small that only a held parse can reach it: nothing else is
      # timed, and this file is still in its parser
      held_pid =
        with_env(:backstop_parse_ms, 25, fn ->
          held = Task.async(fn -> TreeSitter.parse("held/huge.js", :javascript, source) end)

          assert_receive {:trailblazer_event, :parse, {:started, "held/huge.js", _worker, pid}},
                         60_000

          assert {:error, :timeout} = Task.await(held, 60_000)

          assert anomaly =
                   Enum.find(
                     Anomaly.list(),
                     &(&1.kind == "parse" and &1.subject == "held/huge.js")
                   )

          assert anomaly.evidence["lang"] == "javascript"
          assert anomaly.evidence["bytes"] == byte_size(source)

          # the held parser's OS process ended with its Port
          refute pid in TreeSitter.os_pids()
          pid
        end)

      # the pool is whole again, and the next file is parsed by a new parser
      assert {:ok, _} = TreeSitter.parse("held/next.js", :javascript, "const next = 1;\n")

      assert_receive {:trailblazer_event, :parse, {:started, "held/next.js", _worker, fresh}},
                     30_000

      refute fresh == held_pid

      # and both parsers are open again, each in a process of its own
      assert {:ok, _} = TreeSitter.parse("held/last.js", :javascript, "const last = 1;\n")
      assert length(TreeSitter.os_pids()) == 2
    end)
  end

  test "a caller that dies while its file is queued is dropped and the queue goes on" do
    a = Task.async(fn -> TreeSitter.parse("queued/a.js", :javascript, held_javascript()) end)
    b = Task.async(fn -> TreeSitter.parse("queued/b.js", :javascript, held_javascript()) end)

    assert_receive {:trailblazer_event, :parse, {:started, "queued/a.js", _worker_a, _pid_a}},
                   60_000

    assert_receive {:trailblazer_event, :parse, {:started, "queued/b.js", _worker_b, _pid_b}},
                   60_000

    dead =
      Task.async(fn -> TreeSitter.parse("queued/dead.js", :javascript, "const dead = 1;\n") end)

    assert eventually(fn -> waiting() == 1 end)
    Task.shutdown(dead, :brutal_kill)

    assert {:ok, _} = Task.await(a, 60_000)
    assert {:ok, _} = Task.await(b, 60_000)

    # the queue went on, and the dead caller's file was never parsed
    assert {:ok, _} = TreeSitter.parse("queued/last.js", :javascript, "const last = 1;\n")
    refute_receive {:trailblazer_event, :parse, {:started, "queued/dead.js", _worker, _pid}}, 50
  end

  # The pool's own view of the world, for a test that has to be somewhere the
  # public API cannot reach: its queue, and its parsers' Ports.
  defp waiting, do: :sys.get_state(TreeSitter).queue |> :queue.len()

  defp close_parsers do
    for {_id, worker} <- :sys.get_state(TreeSitter).workers do
      :sys.replace_state(worker.pid, fn state ->
        if state.port, do: Port.close(state.port)
        %{state | port: nil}
      end)
    end
  end

  defp with_env(key, value, fun) do
    previous = Application.fetch_env(:trailblazer, key)
    Application.put_env(:trailblazer, key, value)

    try do
      fun.()
    after
      case previous do
        {:ok, was} -> Application.put_env(:trailblazer, key, was)
        :error -> Application.delete_env(:trailblazer, key)
      end
    end
  end

  # A file big enough to still be inside a parser while the test does its next
  # thing: tree-sitter takes about half a second on this one.
  defp held_javascript do
    Enum.map_join(1..5_000, "\n", fn i ->
      "function f#{i}(a, b) { return a + b; }\nclass C#{i} { m() {} }"
    end)
  end

  defp eventually(check, tries \\ 100) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(check, tries - 1)
    end
  end

  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
