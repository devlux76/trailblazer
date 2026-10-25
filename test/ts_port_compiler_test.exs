defmodule Mix.Tasks.Compile.TsPortTest do
  @moduledoc """
  The Port's compiler decides when to run cargo. Here cargo is a shell script
  that counts its builds and leaves a binary where the compiler expects one,
  in a crate made for the test, so what is checked is the decision and not
  this machine's toolchain.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Compile.TsPort

  setup do
    root =
      Path.join(System.tmp_dir!(), "trailblazer-ts_port-#{System.unique_integer([:positive])}")

    crate = Path.join([root, "native", "ts_port"])
    File.mkdir_p!(Path.join(crate, "src"))
    File.write!(Path.join(crate, "Cargo.toml"), ~s([package]\nname = "ts_port"\n))
    File.write!(Path.join(crate, "Cargo.lock"), "version = 4\n")
    File.write!(Path.join(crate, "build.rs"), "fn main() {}\n")
    File.write!(Path.join([crate, "src", "main.rs"]), "fn main() {}\n")

    builds = Path.join(root, "builds")
    cargo = Path.join(root, "cargo")

    File.write!(cargo, """
    #!/bin/sh
    echo built >> #{builds}
    mkdir -p #{crate}/target/release
    printf 'the Port' > #{crate}/target/release/ts_port
    """)

    File.chmod!(cargo, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, crate: crate, cargo: cargo, builds: builds}
  end

  test "the binary cargo builds is the one the Port opens", %{root: root, cargo: cargo} do
    assert :ok = TsPort.build(root, cargo)
    assert File.read!(Path.join([root, "priv", "ts_port"])) == "the Port"
  end

  test "a build with nothing to do is left alone", ctx do
    assert :ok = TsPort.build(ctx.root, ctx.cargo)
    age_inputs(ctx.crate)
    assert :ok = TsPort.build(ctx.root, ctx.cargo)
    assert builds(ctx) == 1
  end

  for input <- ["Cargo.lock", "build.rs", "Cargo.toml", "src/main.rs"] do
    test "a newer #{input} builds again", ctx do
      assert :ok = TsPort.build(ctx.root, ctx.cargo)
      age_inputs(ctx.crate)
      File.touch!(Path.join(ctx.crate, unquote(input)))
      assert :ok = TsPort.build(ctx.root, ctx.cargo)
      assert builds(ctx) == 2
    end
  end

  # The inputs and the binary built from them, all an hour old: a file touched
  # now is newer than the binary, whatever the file system's clock resolution.
  defp age_inputs(crate) do
    hour_ago = System.os_time(:second) - 3600
    binary = Path.join([crate, "..", "..", "priv", "ts_port"])

    for path <- [binary | Path.wildcard(Path.join(crate, "**"))], File.regular?(path) do
      File.touch!(path, hour_ago)
    end
  end

  defp builds(%{builds: builds}) do
    builds |> File.read!() |> String.split("\n", trim: true) |> length()
  end
end
