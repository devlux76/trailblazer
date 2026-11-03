defmodule Trailblazer.Loop.ArtifactsTest do
  use ExUnit.Case, async: false
  alias Trailblazer.Loop.Artifacts

  setup do
    root = Path.join(System.tmp_dir!(), "artifact-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    git(root, ["init", "-q"])
    git(root, ["config", "user.name", "Artifact test"])
    git(root, ["config", "user.email", "artifact@example.invalid"])
    File.write!(Path.join(root, "source.txt"), "source")
    File.write!(Path.join(root, "out.txt"), "old")
    git(root, ["add", "."])
    git(root, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture"])
    %{root: root}
  end

  defp git(root, args) do
    {out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    out
  end

  defp policy(root, command, paths \\ ["out.txt"], definitions \\ ["source.txt"]) do
    {:ok, policies} =
      Artifacts.policies(
        %{
          root => %{
            "check" => %{
              "prepare" => command,
              "paths" => paths,
              "definitions" => definitions
            }
          }
        },
        %{root => ["check"]}
      )

    Artifacts.select(policies, root, "check")
  end

  test "policy cannot grant a new repository/check or unsafe output", %{root: root} do
    raw = %{
      root => %{
        "not admitted" => %{"prepare" => "true", "paths" => ["out.txt"], "definitions" => []}
      }
    }

    assert {:error, :invalid_artifacts} = Artifacts.policies(raw, %{root => ["check"]})

    for path <- [
          "../escape",
          "/tmp/escape",
          ".git/config",
          "node_modules/x",
          "deps/x",
          "_build/x",
          "target/x",
          "out/*.js"
        ] do
      raw =
        put_in(raw, [root], %{
          "check" => %{"prepare" => "true", "paths" => [path], "definitions" => []}
        })

      assert {:error, :invalid_artifacts} = Artifacts.policies(raw, %{root => ["check"]})
    end
  end

  test "preparation records declared changes and changed build definitions", %{root: root} do
    p = policy(root, "printf new > out.txt")
    File.write!(Path.join(root, "source.txt"), "edited by coder")
    assert {:ok, result} = Artifacts.prepare(root, p)
    assert result.paths == ["out.txt"]
    assert result.definitions_changed == ["source.txt"]
    assert File.read!(Path.join(root, "out.txt")) == "new"
    assert {:ok, _} = Artifacts.verify(root, p)
  end

  test "stale output fails independent or integration verification", %{root: root} do
    p = policy(root, "printf new > out.txt")
    assert {:error, %{reason: :regeneration_required}} = Artifacts.verify(root, p)
  end

  test "scope violations and failed build cannot succeed", %{root: root} do
    assert {:error, %{reason: :outside_outputs, paths: ["source.txt"]}} =
             Artifacts.prepare(root, policy(root, "printf bad > source.txt"))

    assert {:error, %{reason: :preparation_failed}} =
             Artifacts.prepare(root, policy(root, "exit 7"))
  end

  test "failed commands do not hide scope violations", %{root: root} do
    assert {:error, %{reason: :outside_outputs, paths: ["source.txt"]}} =
             Artifacts.prepare(root, policy(root, "printf bad > source.txt; exit 7"))
  end

  test "tracked dependency files remain protected even when dependency caches are skipped", %{
    root: root
  } do
    File.mkdir!(Path.join(root, "node_modules"))
    File.write!(Path.join(root, "node_modules/tracked.txt"), "owned source")
    git(root, ["add", "."])
    git(root, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "tracked dependency fixture"])

    assert {:error, %{reason: :outside_outputs, paths: ["node_modules/tracked.txt"]}} =
             Artifacts.prepare(root, policy(root, "printf bad > node_modules/tracked.txt"))
  end

  test "new undeclared files, modes and Git state are checked", %{root: root} do
    assert {:error, %{reason: :outside_outputs, paths: ["unexpected.txt"]}} =
             Artifacts.prepare(root, policy(root, "printf bad > unexpected.txt"))

    File.rm!(Path.join(root, "unexpected.txt"))

    assert {:error, %{reason: :outside_outputs, paths: ["source.txt"]}} =
             Artifacts.prepare(root, policy(root, "chmod +x source.txt"))

    assert {:error, %{reason: :git_state_changed}} =
             Artifacts.prepare(root, policy(root, "git add source.txt"))
  end

  test "tampering or a symlink output is refused before the command", %{root: root} do
    p = policy(root, "touch ran")

    assert {:error, %{reason: :invalid_policy}} =
             Artifacts.prepare(root, Map.put(p, "prepare", "true"))

    refute File.exists?(Path.join(root, "ran"))
    File.rm!(Path.join(root, "out.txt"))
    File.ln_s!("source.txt", Path.join(root, "out.txt"))
    assert {:error, %{reason: :unsafe_output}} = Artifacts.prepare(root, p)
    refute File.exists?(Path.join(root, "ran"))
  end

  test "a declared new file and its parent can be created", %{root: root} do
    assert {:ok, %{paths: ["dist/new.txt"]}} =
             Artifacts.prepare(
               root,
               policy(root, "mkdir -p dist; printf new > dist/new.txt", ["dist/new.txt"])
             )

    assert {:ok, _} =
             Artifacts.verify(root, policy(root, "printf new > dist/new.txt", ["dist/new.txt"]))
  end

  test "declared deletion is reproducible and a nonreproducible build is refused", %{root: root} do
    assert {:ok, %{paths: ["out.txt"], deleted_paths: ["out.txt"]}} =
             Artifacts.prepare(root, policy(root, "rm -f out.txt"))

    assert {:ok, _} = Artifacts.verify(root, policy(root, "rm -f out.txt"))
    File.write!(Path.join(root, "out.txt"), "0")

    p =
      policy(
        root,
        ~S|python3 -c 'from pathlib import Path; p=Path("out.txt"); p.write_text(str(int(p.read_text())+1))'|
      )

    assert {:ok, _} = Artifacts.prepare(root, p)
    assert {:error, %{reason: :regeneration_required}} = Artifacts.verify(root, p)
  end

  test "nested and ignored cache writes fail closed", %{root: root} do
    File.mkdir_p!(Path.join(root, "packages/a/node_modules"))
    File.write!(Path.join(root, ".gitignore"), ".local-cache\n")

    assert {:error, %{reason: :outside_outputs, paths: ["packages/a/node_modules/cache"]}} =
             Artifacts.prepare(root, policy(root, "printf cache > packages/a/node_modules/cache"))

    assert {:error, %{reason: :outside_outputs, paths: [".local-cache"]}} =
             Artifacts.prepare(root, policy(root, "printf cache > .local-cache"))
  end

  test "two individually correct candidates can merge cleanly with a stale bundle", %{root: root} do
    File.write!(Path.join(root, "a.txt"), "1")
    File.write!(Path.join(root, "b.txt"), "1")

    File.write!(Path.join(root, "build.py"), ~S"""
    from pathlib import Path
    a=int(Path("a.txt").read_text()); b=int(Path("b.txt").read_text())
    Path("out.txt").write_text(f"a={a}" + "\n"*10 + f"b={b}" + "\n"*10 + f"sum={a+b}\n")
    """)

    p = policy(root, "python3 build.py", ["out.txt"], ["build.py"])
    assert {:ok, _} = Artifacts.prepare(root, p)
    git(root, ["add", "."])
    git(root, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "build fixture"])
    base = String.trim(git(root, ["rev-parse", "HEAD"]))
    git(root, ["checkout", "-qb", "candidate-a"])
    File.write!(Path.join(root, "a.txt"), "2")
    assert {:ok, _} = Artifacts.prepare(root, p)
    git(root, ["add", "."])
    git(root, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "candidate a"])
    git(root, ["checkout", "-qb", "candidate-b", base])
    File.write!(Path.join(root, "b.txt"), "2")
    assert {:ok, _} = Artifacts.prepare(root, p)
    git(root, ["add", "."])
    git(root, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "candidate b"])
    git(root, ["checkout", "-q", "candidate-a"])

    git(root, [
      "-c",
      "core.hooksPath=/dev/null",
      "merge",
      "--no-ff",
      "-qm",
      "integration fixture",
      "candidate-b"
    ])

    assert File.read!(Path.join(root, "out.txt")) =~ "sum=3"
    assert {:error, %{reason: :regeneration_required}} = Artifacts.verify(root, p)
    assert File.read!(Path.join(root, "out.txt")) =~ "sum=4"
    git(root, ["add", "out.txt"])
    git(root, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "explicit regeneration"])
    assert {:ok, _} = Artifacts.verify(root, p)
  end

  test "recreating a declared output parent may normalize its directory mode", %{root: root} do
    File.mkdir_p!(Path.join(root, "dist"))
    File.chmod!(Path.join(root, "dist"), 0o775)
    File.write!(Path.join(root, "dist/bundle"), "old")

    p =
      policy(root, "rm -rf dist && mkdir -m 755 dist && printf new > dist/bundle", ["dist/bundle"])

    assert {:ok, result} = Artifacts.prepare(root, p)
    assert result.paths == ["dist/bundle"]
    assert {:ok, _} = Artifacts.verify(root, p)
    File.mkdir_p!(Path.join(root, "unrelated"))
    File.chmod!(Path.join(root, "unrelated"), 0o755)
    p = policy(root, "chmod 700 unrelated", ["dist/bundle"])

    assert {:error, %{reason: :outside_outputs, paths: ["unrelated"]}} =
             Artifacts.prepare(root, p)
  end
end
