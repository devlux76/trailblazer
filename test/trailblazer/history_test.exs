defmodule Trailblazer.HistoryTest do
  use ExUnit.Case, async: false

  alias Trailblazer.{History, Vectors}

  defmodule FakeEmbed do
    def documents(docs, _opts) do
      send(self(), {:embedded, length(docs)})
      {:ok, Enum.map(docs, fn {path, _} -> vec(path) end)}
    end

    def query(text, _opts), do: {:ok, vec(text)}
    defp vec(text), do: for(w <- ~w(a.ex b.ex c.ex), do: if(text =~ w, do: 1.0, else: 0.0))
  end

  defmodule FakeVectors do
    def ensure(_root, _opts), do: :ok

    def put(_root, points, _opts) do
      Process.put(
        :points,
        Map.merge(Process.get(:points, %{}), Map.new(points, &{&1.id, &1.vector}))
      )

      :ok
    end

    def delete(_root, ids, _opts) do
      Process.put(:points, Map.drop(Process.get(:points, %{}), ids))
      :ok
    end

    def nearest(_root, vector, limit, _opts) do
      hits =
        Process.get(:points, %{})
        |> Enum.map(fn {id, v} -> {id, Enum.zip_with(v, vector, &(&1 * &2)) |> Enum.sum()} end)
        |> Enum.sort_by(&(-elem(&1, 1)))
        |> Enum.take(limit)

      {:ok, hits}
    end
  end

  @opts [embed: FakeEmbed, vectors: FakeVectors]

  setup do
    dir = Path.join(System.tmp_dir!(), "tb-history-#{System.unique_integer([:positive])}")
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "lib"))
    pii = Path.join(dir, "pii-patterns")
    File.write!(pii, "# test patterns\nSECRET-[0-9]+\n")
    git(repo, ["init", "-q", "-b", "main"])
    File.rm_rf!(History.root())

    on_exit(fn ->
      File.rm_rf!(dir)
      File.rm_rf!(History.root())
    end)

    Process.delete(:points)
    %{repo: repo, opts: @opts ++ [pii_file: pii, home: "/home/someone"]}
  end

  defp git(repo, args, env \\ []) do
    {out, 0} = System.cmd("git", args, cd: repo, env: env, stderr_to_stdout: true)
    out
  end

  # A commit at `at` (unix seconds) writing `files` (%{path => text}).
  defp commit(repo, files, message, at) do
    for {path, text} <- files do
      File.mkdir_p!(Path.dirname(Path.join(repo, path)))
      File.write!(Path.join(repo, path), text)
    end

    git(repo, ["add", "-A"])
    date = "#{at} +0000"

    git(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", message], [
      {"GIT_AUTHOR_DATE", date},
      {"GIT_COMMITTER_DATE", date}
    ])

    String.trim(git(repo, ["rev-parse", "HEAD"]))
  end

  defp lines(n, tag), do: Enum.map_join(1..n, "", &"#{tag} line #{&1}\n")

  test "reachable worked changes become entries; snapshots, bulk, lock and binary files do not",
       %{repo: repo, opts: opts} do
    t = 1_800_000_000
    a = commit(repo, %{"lib/a.ex" => lines(5, "a")}, "Add a bug:1111111", t)
    commit(repo, %{"lib/x.ex" => "x\n"}, "Squashed snapshot of all prior work", t + 10)
    commit(repo, %{"mix.lock" => "lock\n", "lib/b.ex" => "b\n"}, "Add b and lock", t + 20)
    File.write!(Path.join(repo, "lib/bin.dat"), <<0, 1, 2, 0, 255>>)
    commit(repo, %{}, "binary", t + 30)
    bulk = Map.new(1..61, &{"gen/f#{&1}.ex", "f\n"})
    commit(repo, bulk, "Import generated files", t + 40)

    # a branch commit that is then deleted is unreachable
    git(repo, ["switch", "-q", "-c", "gone"])
    commit(repo, %{"lib/c.ex" => "c\n"}, "on a deleted branch", t + 50)
    git(repo, ["switch", "-q", "main"])
    git(repo, ["branch", "-q", "-D", "gone"])

    {:ok, entries, info} = History.entries(repo, opts)

    assert Enum.map(entries, &{&1.path, &1.commit}) |> Enum.sort() ==
             [
               {"lib/a.ex", a},
               {"lib/b.ex", entries |> Enum.find(&(&1.path == "lib/b.ex")) |> Map.get(:commit)}
             ]

    assert info.dropped == 0
    e = Enum.find(entries, &(&1.path == "lib/a.ex"))
    assert e.bug == "1111111"
    assert e.request == "Add a bug:1111111"
    assert e.patch =~ "+a line 1"
    assert e.new_ranges == [[1, 5]]
    assert e.point == Vectors.point_id(e.id)
  end

  test "PII drops the entry; the home path is written as ~", %{repo: repo, opts: opts} do
    commit(repo, %{"lib/a.ex" => "token SECRET-42\n"}, "leak", 1_800_000_000)

    commit(
      repo,
      %{"lib/b.ex" => "path /home/someone/x\n"},
      "see /home/someone/notes",
      1_800_000_100
    )

    {:ok, [e], info} = History.entries(repo, opts)
    assert info.dropped == 1
    assert e.path == "lib/b.ex"
    assert e.request == "see ~/notes"
    assert e.patch =~ "+path ~/x"
    refute e.patch =~ "/home/someone"
  end

  test "the screen ignores case, covers the path and drops text that is not utf-8",
       %{repo: repo, opts: opts} do
    t = 1_800_000_000
    commit(repo, %{"lib/a.ex" => "token secret-42\n"}, "lowercase leak", t)
    commit(repo, %{"lib/Secret-7.ex" => "x\n"}, "leak in a path", t + 10)
    commit(repo, %{"lib/latin.ex" => <<"caf", 0xE9, "\n">>}, "latin-1", t + 20)
    commit(repo, %{"lib/ok.ex" => "fine\n"}, "fine", t + 30)

    {:ok, entries, info} = History.entries(repo, opts)
    assert Enum.map(entries, & &1.path) == ["lib/ok.ex"]
    assert info.dropped == 3
  end

  test "missing, empty or broken patterns refuse the run", %{repo: repo, opts: opts} do
    commit(repo, %{"lib/a.ex" => "a\n"}, "a", 1_800_000_000)
    dir = Path.dirname(repo)

    assert {:error, :pii_patterns} =
             History.entries(repo, Keyword.put(opts, :pii_file, Path.join(dir, "none")))

    for {name, text} <- [{"empty", "# only a comment\n\n"}, {"broken", "unclosed(\n"}] do
      File.write!(Path.join(dir, name), text)

      assert {:error, :pii_patterns} =
               History.entries(repo, Keyword.put(opts, :pii_file, Path.join(dir, name)))
    end

    assert {:error, :pii_patterns} =
             History.ingest([repo], Keyword.put(opts, :pii_file, Path.join(dir, "none")))
  end

  test "an oversized hunk is split at line boundaries into pieces git applies",
       %{repo: repo, opts: opts} do
    t = 1_800_000_000
    commit(repo, %{"lib/a.ex" => lines(400, "a")}, "base", t)
    commit(repo, %{"lib/a.ex" => lines(400, "b")}, "rewrite every line", t + 100)

    chunks =
      History.entries(repo, opts)
      |> elem(1)
      |> Enum.filter(&(&1.request == "rewrite every line"))
      |> Enum.sort_by(& &1.chunk)

    assert length(chunks) > 1

    for c <- chunks do
      assert String.starts_with?(c.patch, "--- a/lib/a.ex\n+++ b/lib/a.ex\n@@ -")
      refute c.old_ranges == []
    end

    # every piece's header counts are right: together they apply to the parent
    [header | _] = String.split(hd(chunks).patch, ~r/^(?=@@ )/m)

    hunks =
      Enum.map_join(chunks, "", fn c ->
        c.patch |> String.split(~r/^(?=@@ )/m) |> tl() |> Enum.join()
      end)

    git(repo, ["checkout", "-q", "HEAD~1", "--", "lib/a.ex"])
    patch = Path.join(Path.dirname(repo), "pieces.patch")
    File.write!(patch, header <> hunks)
    git(repo, ["apply", patch])
    assert File.read!(Path.join(repo, "lib/a.ex")) == lines(400, "b")
  end

  test "context lines do not make a later change a fix-up", %{repo: repo, opts: opts} do
    t = 1_800_000_000
    commit(repo, %{"lib/a.ex" => lines(10, "a")}, "base", t)

    first =
      commit(
        repo,
        %{"lib/a.ex" => String.replace(lines(10, "a"), "a line 1\n", "A line 1\n")},
        "One bug:4444444",
        t + 10
      )

    later =
      String.replace(lines(10, "a"), "a line 1\n", "A line 1\n")
      |> String.replace("a line 4\n", "A line 4\n")

    commit(repo, %{"lib/a.ex" => later}, "Four bug:4444444", t + 20)

    {:ok, entries, _} = History.entries(repo, opts)
    e = Enum.find(entries, &(&1.commit == first))
    assert e.new_ranges == [[1, 1]]
    assert e.label == "succeeded"
  end

  test "labels: reverted, fixed up within a day by the same bug, else succeeded",
       %{repo: repo, opts: opts} do
    t = 1_800_000_000
    first = commit(repo, %{"lib/a.ex" => lines(5, "a")}, "Write a bug:2222222", t)

    commit(
      repo,
      %{"lib/a.ex" => String.replace(lines(5, "a"), "a line 3", "A line 3")},
      "Fix a bug:2222222",
      t + 3600
    )

    b = commit(repo, %{"lib/b.ex" => "b\n"}, "Add b", t + 7200)
    git(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "revert", "--no-edit", b])
    late = commit(repo, %{"lib/c.ex" => lines(3, "c")}, "Write c bug:3333333", t + 10_000)
    commit(repo, %{"lib/c.ex" => "changed\n"}, "Fix c bug:3333333", t + 10_000 + 2 * 86_400)

    {:ok, entries, _} = History.entries(repo, opts)
    label = fn sha, path -> Enum.find(entries, &(&1.commit == sha and &1.path == path)).label end

    assert label.(first, "lib/a.ex") == "fixed_up"
    assert label.(b, "lib/b.ex") == "reverted"
    # changed again, but two days later: not a fix-up
    assert label.(late, "lib/c.ex") == "succeeded"
  end

  test "an open card labels its entries open" do
    e = %{
      commit: "abc",
      bug: "1234567",
      path: "p",
      at: 1,
      old_ranges: [],
      new_ranges: [],
      card_status: "open",
      label: "succeeded"
    }

    assert [%{label: "open"}] = History.label([e], [])
    assert [%{label: "succeeded"}] = History.label([%{e | card_status: "closed"}], [])
  end

  test "a long diff is cut at hunk boundaries, each chunk with the file header",
       %{repo: repo, opts: opts} do
    t = 1_800_000_000
    commit(repo, %{"lib/a.ex" => lines(2000, "a")}, "base", t)

    changed =
      lines(2000, "a")
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {l, i} ->
        if rem(i, 40) == 0, do: l <> " changed #{String.duplicate("x", 60)}", else: l
      end)

    commit(repo, %{"lib/a.ex" => changed}, "many hunks", t + 100)
    {:ok, entries, _} = History.entries(repo, opts)
    chunks = entries |> Enum.filter(&(&1.request == "many hunks")) |> Enum.sort_by(& &1.chunk)

    assert length(chunks) > 1
    assert Enum.map(chunks, & &1.chunk) == Enum.to_list(0..(length(chunks) - 1))
    assert Enum.uniq_by(chunks, & &1.id) == chunks

    for c <- chunks do
      assert String.starts_with?(c.patch, "--- a/lib/a.ex\n+++ b/lib/a.ex\n@@ ")

      {_, text} =
        History.document(%{"path" => c.path, "request" => c.request, "patch" => c.patch})

      assert String.length(text) <= 6_000
    end
  end

  test "ingest embeds once, resumes, refreshes and purges unreachable commits",
       %{repo: repo, opts: opts} do
    t = 1_800_000_000
    commit(repo, %{"lib/a.ex" => "a\n"}, "a", t)
    git(repo, ["switch", "-q", "-c", "topic"])
    commit(repo, %{"lib/b.ex" => "b\n"}, "b", t + 10)

    assert {:ok, %{"repo" => %{entries: 2, new: 2, purged: 0}}} = History.ingest([repo], opts)
    assert_received {:embedded, 2}
    assert map_size(History.load()) == 2
    assert map_size(Process.get(:points)) == 2

    # nothing new: nothing embedded
    assert {:ok, %{"repo" => %{new: 0, purged: 0}}} = History.ingest([repo], opts)
    refute_received {:embedded, _}

    # the topic branch goes: its entry and vector are purged
    git(repo, ["switch", "-q", "main"])
    git(repo, ["branch", "-q", "-D", "topic"])
    assert {:ok, %{"repo" => %{entries: 1, purged: 1}}} = History.ingest([repo], opts)
    assert [%{"path" => "lib/a.ex"}] = Map.values(History.load())
    assert map_size(Process.get(:points)) == 1

    assert {:ok, [{_, %{"path" => "lib/a.ex"}}]} = History.similar("a.ex", 1, opts)

    # stored text that no longer matches what would be embedded is re-embedded
    file = Path.join(History.root(), "entries.jsonl")
    [e] = Map.values(History.load())
    File.write!(file, Jason.encode!(Map.put(e, "doc", "stale")) <> "\n")
    assert {:ok, %{"repo" => %{new: 1, purged: 0}}} = History.ingest([repo], opts)
    assert_received {:embedded, 1}
    assert map_size(Process.get(:points)) == 1
  end

  test "a point id already held by another entry is refused", %{repo: repo, opts: opts} do
    commit(repo, %{"lib/a.ex" => "a\n"}, "a", 1_800_000_000)
    {:ok, [e], _} = History.entries(repo, opts)
    File.mkdir_p!(History.root())

    squatter = %{
      "id" => "other",
      "point" => e.point,
      "repo_path" => "/elsewhere",
      "at" => 0,
      "repo" => "x",
      "path" => "p",
      "chunk" => 0
    }

    File.write!(Path.join(History.root(), "entries.jsonl"), Jason.encode!(squatter) <> "\n")

    assert {:error, {:point_collision, _, "other"}} = History.ingest([repo], opts)
  end

  test "point ids are positive, stable and 63-bit" do
    id = Vectors.point_id("x")
    assert id == Vectors.point_id("x")
    assert id > 0 and id < Bitwise.bsl(1, 63)
    refute id == Vectors.point_id("y")
  end
end
