defmodule Trailblazer.IndexerGitTest do
  # Design §13.7: what changed comes from git; requests reconcile first.
  use ExUnit.Case, async: false
  alias Trailblazer.{Embed, Events, Files, Indexer, Store, Vectors}

  setup do
    root =
      Path.join(System.tmp_dir!(), "trailblazer-gitidx-#{System.unique_integer([:positive])}")

    File.cp_r!(Path.expand("../fixtures/mini", __DIR__), root)
    git(root, ["init", "-q", "-b", "main"])
    commit(root, "init")
    parent = self()

    # Every file the indexer reads is reported, so a test can say which.
    read = fn repo, path ->
      send(parent, {:read, path})
      Files.read(repo, path)
    end

    on_exit(fn ->
      if pid = Indexer.whereis(root), do: GenServer.stop(pid)
      # the real Vectors made a collection for this repo: leave none behind
      Vectors.drop(root)
      File.rm_rf!(root)
    end)

    %{
      root: root,
      opts: [
        embed: Embed,
        vectors: Vectors,
        filesystem: false,
        embedding: :paused,
        read_file: read
      ]
    }
  end

  defmodule FakeEmbed do
    def documents(docs, _opts), do: {:ok, Enum.map(docs, fn _ -> [1.0] end)}
  end

  defmodule FakeVectors do
    def ensure(_, _), do: :ok
    def put(_, _, _), do: :ok
    def delete(_, _, _), do: :ok
  end

  test "a file ignored after it was indexed does not stay pending for good (J29)",
       %{root: root, opts: opts} do
    # Untracked and not ignored, so it is indexed; embedding is paused, so its
    # definitions are pending when git stops reporting it.
    note = Path.join(root, "lib/note.ex")
    File.write!(note, "defmodule Mini.Note do; def a, do: 1; end")
    opts = Keyword.merge(opts, embed: FakeEmbed, vectors: FakeVectors)
    {:ok, _} = Indexer.watch(root, opts)
    {:ok, id} = Store.add_repo(root)
    assert Store.nodes_by_qualified(id, "Mini.Note.a/0") != []

    File.write!(Path.join(root, ".git/info/exclude"), "lib/note.ex\n", [:append])
    File.write!(note, "defmodule Mini.Note do; def b, do: 2; end")
    assert {:ok, _} = Indexer.fresh(root)
    assert Store.nodes_by_qualified(id, "Mini.Note.a/0") != []

    :ok = Indexer.resume_embedding(root)
    eventually(fn -> Store.pending_vectors(id, 1_000) == [] end)
    refute Enum.any?(Store.files(id), &(&1.path == "lib/note.ex"))
  end

  test "the first sync is full and records HEAD; a restart with nothing changed reads nothing",
       %{root: root, opts: opts} do
    {:ok, pid} = Indexer.watch(root, opts)
    {:ok, id} = Store.add_repo(root)
    head = root |> git(["rev-parse", "HEAD"]) |> String.trim()
    assert Store.indexed_head(id) == head
    assert Indexer.status(root).head == head
    assert reads() != []

    GenServer.stop(pid)
    {:ok, _} = Indexer.watch(root, opts)
    assert reads() == []
  end

  test "an uncommitted edit is seen by fresh/1, and only that file is read",
       %{root: root, opts: opts} do
    {:ok, _} = Indexer.watch(root, opts)
    {:ok, id} = Store.add_repo(root)
    reads()
    File.write!(Path.join(root, "lib/app.ex"), "defmodule Mini.App do; def edited, do: :ok; end")
    File.write!(Path.join(root, "lib/new.ex"), "defmodule Mini.New do; def fresh, do: :ok; end")

    assert {:ok, %{parsed: 2, head: head}} = Indexer.fresh(root)
    assert head == Store.indexed_head(id)
    assert Enum.sort(reads()) == ["lib/app.ex", "lib/new.ex"]
    assert Store.nodes_by_qualified(id, "Mini.App.edited/0") != []
    assert Store.nodes_by_qualified(id, "Mini.New.fresh/0") != []
  end

  test "J33: a deleted formerly-untracked file leaves no ghost", %{root: root, opts: opts} do
    {:ok, _} = Indexer.watch(root, opts)
    {:ok, id} = Store.add_repo(root)
    path = Path.join(root, "lib/temporary.ex")
    File.write!(path, "defmodule Mini.Temporary do; def probe, do: :ok; end")
    assert {:ok, %{parsed: 1}} = Indexer.fresh(root)
    assert Store.nodes_by_qualified(id, "Mini.Temporary.probe/0") != []
    File.rm!(path)
    assert {:ok, %{deleted: 1}} = Indexer.fresh(root)
    assert Store.nodes_by_qualified(id, "Mini.Temporary.probe/0") == []
    refute Enum.any?(Store.files(id), &(&1.path == "lib/temporary.ex"))
    assert {:ok, %{deleted: 0, parsed: 0}} = Indexer.fresh(root)
  end

  test "J33: restoring a tracked file reindexes its committed contents", %{root: root, opts: opts} do
    {:ok, _} = Indexer.watch(root, opts)
    {:ok, id} = Store.add_repo(root)
    File.write!(Path.join(root, "lib/app.ex"), "defmodule Mini.App do; def edited, do: :ok; end")
    assert {:ok, %{parsed: 1}} = Indexer.fresh(root)
    assert Store.nodes_by_qualified(id, "Mini.App.edited/0") != []
    git(root, ["restore", "lib/app.ex"])
    reads()
    assert {:ok, %{parsed: 1}} = Indexer.fresh(root)
    assert reads() == ["lib/app.ex"]
    assert Store.nodes_by_qualified(id, "Mini.App.edited/0") == []
    assert Store.nodes_by_qualified(id, "Mini.App.run/1") != []
  end

  test "J33: a prior dirty path can become dirty again after a clean reconciliation", %{
    root: root,
    opts: opts
  } do
    {:ok, _} = Indexer.watch(root, opts)
    {:ok, id} = Store.add_repo(root)
    path = Path.join(root, "lib/app.ex")
    File.write!(path, "defmodule Mini.App do; def first, do: :ok; end")
    assert {:ok, %{parsed: 1}} = Indexer.fresh(root)
    git(root, ["restore", "lib/app.ex"])
    assert {:ok, %{parsed: 1}} = Indexer.fresh(root)
    File.write!(path, "defmodule Mini.App do; def second, do: :ok; end")
    assert {:ok, %{parsed: 1}} = Indexer.fresh(root)
    assert Store.nodes_by_qualified(id, "Mini.App.second/0") != []
    assert Store.nodes_by_qualified(id, "Mini.App.first/0") == []
  end

  test "J33: dirty-path reconciliation survives an indexer restart", %{root: root, opts: opts} do
    {:ok, pid} = Indexer.watch(root, opts)
    {:ok, id} = Store.add_repo(root)
    File.write!(Path.join(root, "lib/app.ex"), "defmodule Mini.App do; def edited, do: :ok; end")
    File.write!(Path.join(root, "lib/temporary.ex"), "defmodule Mini.Temporary do; end")
    assert {:ok, %{parsed: 2}} = Indexer.fresh(root)
    GenServer.stop(pid)
    git(root, ["restore", "lib/app.ex"])
    File.rm!(Path.join(root, "lib/temporary.ex"))
    {:ok, _} = Indexer.watch(root, opts)
    assert Store.nodes_by_qualified(id, "Mini.App.edited/0") == []
    assert Store.nodes_by_qualified(id, "Mini.App.run/1") != []
    assert Store.nodes_by_qualified(id, "Mini.Temporary") == []
  end

  test "J33: a dirty path seen by the initial full sync is revisited after deletion", %{
    root: root,
    opts: opts
  } do
    path = Path.join(root, "lib/temporary.ex")
    File.write!(path, "defmodule Mini.Temporary do; end")
    {:ok, _} = Indexer.watch(root, opts)
    {:ok, id} = Store.add_repo(root)
    assert Store.nodes_by_qualified(id, "Mini.Temporary") != []
    File.rm!(path)
    assert {:ok, %{deleted: 1}} = Indexer.fresh(root)
    assert Store.nodes_by_qualified(id, "Mini.Temporary") == []
  end

  test "J33: an old hot-loaded state learns dirty paths with an empty default", %{
    root: root,
    opts: opts
  } do
    {:ok, pid} = Indexer.watch(root, opts)
    :sys.replace_state(pid, &Map.delete(&1, :git_paths))
    {:ok, id} = Store.add_repo(root)
    File.write!(Path.join(root, "lib/app.ex"), "defmodule Mini.App do; def edited, do: :ok; end")
    assert {:ok, %{parsed: 1}} = Indexer.fresh(root)
    git(root, ["restore", "lib/app.ex"])
    assert {:ok, %{parsed: 1}} = Indexer.fresh(root)
    assert Store.nodes_by_qualified(id, "Mini.App.edited/0") == []
  end

  test "commits since the indexed HEAD are synced, deletions included", %{root: root, opts: opts} do
    {:ok, _} = Indexer.watch(root, opts)
    {:ok, id} = Store.add_repo(root)
    reads()
    File.write!(Path.join(root, "lib/later.ex"), "defmodule Mini.Later do; def x, do: 1; end")
    File.rm!(Path.join(root, "lib/app.ex"))
    commit(root, "later")
    new_head = root |> git(["rev-parse", "HEAD"]) |> String.trim()

    assert {:ok, %{parsed: 1, deleted: 1, head: ^new_head}} = Indexer.fresh(root)
    assert reads() == ["lib/later.ex"]
    assert Store.indexed_head(id) == new_head
    assert Store.nodes_by_qualified(id, "Mini.Later.x/0") != []
    refute Enum.any?(Store.files(id), &(&1.path == "lib/app.ex"))
  end

  test "an indexed HEAD that no longer exists means a full sync (J24)", %{root: root, opts: opts} do
    {:ok, pid} = Indexer.watch(root, opts)
    {:ok, id} = Store.add_repo(root)
    GenServer.stop(pid)
    :ok = Store.set_indexed_head(id, String.duplicate("1", 40))
    reads()
    File.write!(Path.join(root, "lib/app.ex"), "defmodule Mini.App do; def again, do: :ok; end")
    {:ok, _} = Indexer.watch(root, opts)
    # Full: every listed file is compared; the changed one is read.
    assert "lib/app.ex" in reads()
    assert Store.indexed_head(id) == root |> git(["rev-parse", "HEAD"]) |> String.trim()
    assert Store.nodes_by_qualified(id, "Mini.App.again/0") != []
  end

  test "a changed lockfile means a full sync (J25)", %{root: root, opts: opts} do
    {:ok, _} = Indexer.watch(root, opts)
    {:ok, id} = Store.add_repo(root)
    reads()
    # An ignored vendored file changes with its lockfile; git reports only the lockfile.
    File.mkdir_p!(Path.join(root, "deps/lib_a"))
    File.write!(Path.join(root, ".gitignore"), "deps/\n")
    File.write!(Path.join(root, "deps/lib_a/a.ex"), "defmodule LibA do; def v, do: 2; end")
    File.write!(Path.join(root, "mix.lock"), "%{\"lib_a\" => 2}\n")

    assert {:ok, _} = Indexer.fresh(root)
    assert Store.nodes_by_qualified(id, "LibA.v/0") != []
  end

  test "a request during a sync is answered by the next one (J19)", %{root: root, opts: opts} do
    parent = self()
    {:ok, gate} = Agent.start_link(fn -> false end)

    read = fn repo, path ->
      if path == "lib/app.ex" and Agent.get_and_update(gate, &{&1, false}) do
        send(parent, {:held, self()})
        receive do: (:release -> :ok)
      end

      Files.read(repo, path)
    end

    {:ok, _} = Indexer.watch(root, Keyword.put(opts, :read_file, read))
    {:ok, id} = Store.add_repo(root)
    Agent.update(gate, fn _ -> true end)
    File.write!(Path.join(root, "lib/app.ex"), "defmodule Mini.App do; def one, do: :ok; end")
    first = Task.async(fn -> Indexer.fresh(root) end)
    assert_receive {:held, worker}

    # Saved after the running sync asked git: only a later sync can see it.
    File.write!(Path.join(root, "lib/late.ex"), "defmodule Mini.Late do; def l, do: :ok; end")
    second = Task.async(fn -> Indexer.fresh(root) end)
    send(worker, :release)

    assert {:ok, %{generation: g1}} = Task.await(first, :infinity)
    assert {:ok, %{generation: g2}} = Task.await(second, :infinity)
    assert g2 > g1
    assert Store.nodes_by_qualified(id, "Mini.Late.l/0") != []
  end

  test "the git directory moving starts a sync", %{root: root, opts: opts} do
    {:ok, pid} = Indexer.watch(root, opts)
    {:ok, id} = Store.add_repo(root)
    Events.subscribe({:repo, root})
    File.write!(Path.join(root, "lib/staged.ex"), "defmodule Mini.Staged do; def s, do: 1; end")
    git(root, ["add", "lib/staged.ex"])
    send(pid, {:git_state, Path.join(root, ".git")})
    assert_receive {:trailblazer_event, {:repo, ^root}, %{event: :sync_done, result: {:ok, _}}}
    assert Store.nodes_by_qualified(id, "Mini.Staged.s/0") != []
  end

  test "a directory that is not a work tree falls back to a full sync", %{opts: opts} do
    plain =
      Path.join(System.tmp_dir!(), "trailblazer-plain-#{System.unique_integer([:positive])}")

    File.cp_r!(Path.expand("../fixtures/mini", __DIR__), plain)

    on_exit(fn ->
      if pid = Indexer.whereis(plain), do: GenServer.stop(pid)
      # the real Vectors made a collection for this repo: leave none behind
      Vectors.drop(plain)
      File.rm_rf!(plain)
    end)

    {:ok, _} = Indexer.watch(plain, opts)
    assert Indexer.status(plain).head == nil
    File.write!(Path.join(plain, "lib/p.ex"), "defmodule Mini.P do; def p, do: 1; end")
    {:ok, id} = Store.add_repo(plain)
    assert {:ok, %{head: nil}} = Indexer.fresh(plain)
    assert Store.nodes_by_qualified(id, "Mini.P.p/0") != []
  end

  defp eventually(check, tries \\ 200)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, tries) do
    if check.() do
      :ok
    else
      Process.sleep(10)
      eventually(check, tries - 1)
    end
  end

  defp reads(acc \\ []) do
    receive do
      {:read, path} -> reads([path | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp commit(root, message) do
    git(root, ["add", "-A"])
    git(root, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message])
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end
end
