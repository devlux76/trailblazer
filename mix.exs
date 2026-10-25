defmodule Mix.Tasks.Compile.TsPort do
  @moduledoc """
  Builds the tree-sitter Port: a small Rust program that parses JavaScript,
  TypeScript and Python in a process of its own, so that a parser crash costs
  that process and not the VM.

  It lives here, in `mix.exs`, because `mix compile` has to be able to run it on
  the very first compile, before the project's own modules exist. `cargo build
  --release` runs only when the binary is older than the crate's manifest,
  lockfile, build script or sources, so a
  compile that has nothing to do here stays quick.
  """

  use Mix.Task.Compiler

  @recursive false

  @impl Mix.Task.Compiler
  def run(_args), do: build(File.cwd!())

  @doc false
  # The project root and the cargo to run are arguments so that the decision
  # of when to build can be tested without this machine's toolchain.
  def build(root, cargo \\ "cargo") do
    crate = Path.join([root, "native", "ts_port"])
    manifest = Path.join(crate, "Cargo.toml")
    binary = Path.join([root, "priv", "ts_port"])
    built = Path.join([crate, "target", "release", "ts_port"])

    if stale?(manifest, crate, binary) do
      Mix.shell().info("Building the tree-sitter Port")

      case System.cmd(cargo, ["build", "--release", "--manifest-path", manifest],
             cd: root,
             stderr_to_stdout: true
           ) do
        {_out, 0} ->
          File.mkdir_p!(Path.dirname(binary))
          File.cp!(built, binary)

        {out, status} ->
          Mix.raise("cargo build failed (exit #{status}):\n#{out}")
      end
    end

    :ok
  end

  @impl Mix.Task.Compiler
  def clean do
    File.rm(Path.join(File.cwd!(), "priv/ts_port"))
    :ok
  end

  defp stale?(manifest, crate, binary) do
    # what cargo builds from: the manifest, the lockfile that pins the
    # grammars, the build script that links them, and the sources
    sources =
      [manifest, Path.join(crate, "Cargo.lock"), Path.join(crate, "build.rs")] ++
        Path.wildcard(Path.join([crate, "src", "**"])) ++
        Path.wildcard(Path.join([crate, "tests", "**"]))

    newest =
      sources
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&File.stat!/1)
      |> Enum.map(& &1.mtime)
      |> Enum.max(fn -> 0 end)

    case File.stat(binary) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime < newest
      {:error, _reason} -> true
    end
  end
end

defmodule Trailblazer.MixProject do
  use Mix.Project

  def project do
    [
      app: :trailblazer,
      version: "0.1.0",
      elixir: "~> 1.20",
      compilers: [:ts_port] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # The CLI starts nothing of the service: no Store, no Port. It only
      # talks to the running service over the loopback API.
      escript: [main_module: Trailblazer.CLI, app: nil, path: "_build/escript/trailblazer"],
      releases: [trailblazer: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Trailblazer.Application, []}
    ]
  end

  defp deps do
    [
      {:exqlite, ">= 0.0.0"},
      {:req, ">= 0.0.0"},
      {:jason, ">= 0.0.0"},
      {:bandit, ">= 0.0.0"},
      {:plug, ">= 0.0.0"},
      {:file_system, ">= 0.0.0"}
    ]
  end
end
