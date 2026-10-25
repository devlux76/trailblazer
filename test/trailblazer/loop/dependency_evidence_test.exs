defmodule Trailblazer.Loop.DependencyEvidenceTest do
  use ExUnit.Case, async: true

  alias Trailblazer.Loop.DependencyEvidence

  setup do
    repo =
      Path.join(System.tmp_dir!(), "trailblazer-evidence-#{System.unique_integer([:positive])}")

    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(repo) end)
    File.write!(Path.join(repo, "bun.lock"), "{}")
    package = Path.join(repo, "node_modules/@babylonjs/core")
    File.mkdir_p!(Path.join(package, "Maths"))

    File.write!(
      Path.join(package, "package.json"),
      ~s({"name":"@babylonjs/core","version":"9.31.0","types":"index.d.ts"})
    )

    File.write!(Path.join(package, "index.d.ts"), ~s(export * from "./Maths/pure.js";))
    File.write!(Path.join(package, "Maths/pure.d.ts"), ~s(export * from "./math.scalar.js";))

    File.write!(Path.join(package, "Maths/math.scalar.d.ts"), """
    export declare const Scalar: {
        Clamp(value: number, min?: number, max?: number): number;
    };
    """)

    %{
      repo: repo,
      package: package,
      task: %{repo: repo, request: "Add a clamp helper", design: ["Babylon first"]}
    }
  end

  test "installed exports and declaration establish Scalar.Clamp, not a remembered API", %{
    task: task
  } do
    evidence = DependencyEvidence.gather(task)
    text = Enum.map_join(evidence, "\n", fn {path, excerpt} -> path <> "\n" <> excerpt end)
    assert text =~ "9.31.0"
    assert text =~ ~s(export * from "./Maths/pure.js")
    assert text =~ ~s(export * from "./math.scalar.js")
    assert text =~ "export declare const Scalar"
    assert text =~ "Clamp(value: number"
    refute text =~ "MathUtils"
  end

  test "unrelated tasks do not scan dependencies", %{task: task} do
    assert DependencyEvidence.gather(%{task | request: "Rename hello"}) == []
    assert DependencyEvidence.gather(%{task | design: []}) == []
    File.rm!(Path.join(task.repo, "bun.lock"))
    assert DependencyEvidence.gather(task) == []
  end

  test "missing packages and declarations are explicit, without guessing an API", %{
    task: task,
    package: package
  } do
    File.rm_rf!(package)
    assert [{_, message}] = DependencyEvidence.gather(task)
    assert message =~ "unavailable"
    refute message =~ "Scalar.Clamp"
  end

  test "a declaration without the verified exported member is unavailable", %{
    task: task,
    package: package
  } do
    File.write!(
      Path.join(package, "Maths/math.scalar.d.ts"),
      "export declare const MathUtils: {};\n"
    )

    assert [{_, message}] = DependencyEvidence.gather(task)
    assert message =~ "unavailable"
    refute message =~ "MathUtils"
  end

  test "a broken export chain cannot establish a root import", %{task: task, package: package} do
    File.write!(Path.join(package, "index.d.ts"), "export {};\n")
    assert [{_, message}] = DependencyEvidence.gather(task)
    assert message =~ "unavailable"
  end

  test "package metadata cannot redirect reads or bypass its exports map", %{
    task: task,
    package: package
  } do
    for fields <- [
          ~s("types":"../../secret.d.ts"),
          ~s("types":"/tmp/secret.d.ts"),
          ~s("types":"index.d.ts","exports":{})
        ] do
      File.write!(Path.join(package, "package.json"), ~s({"name":"@babylonjs/core",#{fields}}))
      assert [{_, message}] = DependencyEvidence.gather(task)
      assert message =~ "unavailable"
    end
  end

  test "package and declaration symlinks escaping the repository are refused", %{
    task: task,
    package: package
  } do
    outside = task.repo <> "-outside"
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)
    File.write!(Path.join(outside, "secret.d.ts"), "private-marker")
    declaration = Path.join(package, "Maths/math.scalar.d.ts")
    File.rm!(declaration)
    File.ln_s!(Path.join(outside, "secret.d.ts"), declaration)
    assert [{_, message}] = DependencyEvidence.gather(task)
    assert message =~ "unavailable"
    refute message =~ "private-marker"

    File.rm_rf!(package)
    File.ln_s!(outside, package)
    assert [{_, message}] = DependencyEvidence.gather(task)
    assert message =~ "unavailable"
  end

  test "evidence fits its entry and byte budgets, including large declarations", %{
    task: task,
    package: package
  } do
    evidence = DependencyEvidence.gather(task)
    assert length(evidence) <= 20
    assert Enum.sum(Enum.map(evidence, fn {p, t} -> byte_size(p) + byte_size(t) end)) <= 8000

    File.write!(
      Path.join(package, "Maths/math.scalar.d.ts"),
      "export declare const Scalar: {\n    Clamp(value: " <>
        String.duplicate("x", 9_000) <> "): number;\n};\n"
    )

    assert [{_, message}] = DependencyEvidence.gather(task)
    assert message =~ "unavailable"
    File.write!(Path.join(package, "Maths/math.scalar.d.ts"), String.duplicate("x", 200_000))
    assert [{_, message}] = DependencyEvidence.gather(task)
    assert message =~ "unavailable"
  end
end
