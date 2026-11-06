defmodule Trailblazer.CFamilyTest do
  use ExUnit.Case, async: false
  alias Trailblazer.{Indexer, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "trailblazer-c-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "src"))
    File.mkdir_p!(Path.join(root, "include"))

    on_exit(fn ->
      if pid = Indexer.whereis(root), do: GenServer.stop(pid)
      # the indexer made a real collection for this repo: leave none behind
      Trailblazer.Vectors.drop(root)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  defp watch(root) do
    {:ok, _} = Indexer.watch(root, filesystem: false, embedding: :paused)
    {:ok, repo} = Store.add_repo(root)
    repo
  end

  test "C includes reach header file nodes and calls cross the C/C++ family", %{root: root} do
    File.write!(
      Path.join(root, "src/main.c"),
      "#include \"ggml.h\"\n#include <stdio.h>\nint main(void) { return ggml_add(1); }\n"
    )

    File.write!(Path.join(root, "include/ggml.h"), "int ggml_add(int n);\n")
    File.write!(Path.join(root, "src/ggml.cpp"), "int ggml_add(int n) { return n + 1; }\n")
    repo = watch(root)
    [main] = Store.nodes_by_qualified(repo, "main")
    [add] = Store.nodes_by_qualified(repo, "ggml_add")
    edges = Store.edges_from(main.id, ["calls"])
    assert [%{to_id: id}] = edges
    assert id == add.id
    [file] = Store.nodes_by_qualified(repo, "src/main.c")
    [header] = Store.nodes_by_qualified(repo, "include/ggml.h")
    assert [%{to_id: id, uncertain: false}] = Store.edges_from(file.id, ["imports"])
    assert id == header.id
    assert main.start_line == 3
    assert main.end_line == 3
  end

  test "include directory then root precede suffix matches; ambiguous suffixes stay uncertain", %{
    root: root
  } do
    File.write!(
      Path.join(root, "src/main.c"),
      "#include \"ggml.h\"\nint main(void) { return 0; }\n"
    )

    File.write!(Path.join(root, "src/ggml.h"), "int local(void);\n")
    File.write!(Path.join(root, "ggml.h"), "int global(void);\n")
    File.write!(Path.join(root, "include/ggml.h"), "int other(void);\n")
    repo = watch(root)
    [file] = Store.nodes_by_qualified(repo, "src/main.c")

    target_path = fn ->
      Store.edges_from(file.id, ["imports"])
      |> Enum.map(&{Store.node(&1.to_id).path, &1.uncertain})
    end

    assert target_path.() == [{"src/ggml.h", false}]
    File.rm!(Path.join(root, "src/ggml.h"))
    Indexer.sync(root)
    assert target_path.() == [{"ggml.h", false}]
    File.rm!(Path.join(root, "ggml.h"))
    File.mkdir_p!(Path.join(root, "third_party/x"))
    File.write!(Path.join(root, "third_party/x/ggml.h"), "int vendor(void);\n")
    Indexer.sync(root)
    assert Enum.sort(target_path.()) == [{"include/ggml.h", true}, {"third_party/x/ggml.h", true}]

    for i <- 1..10 do
      dir = Path.join(root, "include/v#{i}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "ggml.h"), "int v#{i}(void);\n")
    end

    Indexer.sync(root)
    assert length(target_path.()) == 8
    assert Enum.all?(target_path.(), &elem(&1, 1))
  end

  test "Go and CUDA enter the graph with file-owned imports and contained functions", %{
    root: root
  } do
    File.write!(
      Path.join(root, "server.go"),
      "package main\nimport \"fmt\"\nfunc run() { fmt.Println(1) }\n"
    )

    File.write!(Path.join(root, "kernel.cu"), "__global__ void scale(float *x) { clamp(x); }\n")
    repo = watch(root)
    assert [%{lang: "go"}] = Store.nodes_by_qualified(repo, "run")
    assert [%{lang: "cpp"}] = Store.nodes_by_qualified(repo, "scale")
    [file] = Store.nodes_by_qualified(repo, "server.go")

    assert Enum.any?(
             Store.refs(repo),
             &(&1.from_key == file.key and &1.kind == "imports" and &1.target == "fmt")
           )
  end
end
