defmodule Trailblazer.Loop.DependencyEvidence do
  @moduledoc """
  Bounded installed-source evidence for a Babylon clamp task in a Bun project.
  This deliberately supports one export shape; absent or unfamiliar declarations
  are reported as unavailable, never replaced by a model's remembered API.
  """
  alias Trailblazer.Files

  @package "node_modules/@babylonjs/core"
  @max_file_bytes 64_000
  @max_bytes 8_000
  @max_hits 20

  @spec gather(map()) :: [{String.t(), String.t()}]
  def gather(task) do
    design = task |> Map.get(:design, []) |> List.wrap() |> Enum.join("\n")

    if Regex.match?(~r/\bclamp\b/i, task.request) and
         Regex.match?(~r/babylon/i, design) and bun?(task.repo) do
      installed(task.repo)
    else
      []
    end
  end

  defp bun?(repo),
    do: Enum.any?(~w(bun.lock bun.lockb), &File.regular?(Path.join(repo, &1)))

  defp installed(repo) do
    with {:ok, manifest} <- read(repo, "package.json"),
         {:ok, %{"name" => "@babylonjs/core", "types" => "index.d.ts"} = package} <-
           Jason.decode(manifest),
         false <- Map.has_key?(package, "exports"),
         {:ok, root} <- read(repo, "index.d.ts"),
         {:ok, root_export} <- export(root, "./Maths/pure.js"),
         {:ok, maths} <- read(repo, "Maths/pure.d.ts"),
         {:ok, scalar_export} <- export(maths, "./math.scalar.js"),
         {:ok, scalar} <- read(repo, "Maths/math.scalar.d.ts"),
         [_, header, body] <-
           Regex.run(~r/^(export declare const Scalar: \{)(.*?)^\};/ms, scalar),
         [member] <- Regex.run(~r/^\s*Clamp\([^\n]+;/m, body) do
      evidence = [
        {"#{@package}/package.json", Jason.encode!(Map.take(package, ~w(name version types)))},
        {"#{@package}/index.d.ts", root_export},
        {"#{@package}/Maths/pure.d.ts", scalar_export},
        {"#{@package}/Maths/math.scalar.d.ts", header <> "\n" <> String.trim(member)}
      ]

      if length(evidence) <= @max_hits and
           Enum.sum(Enum.map(evidence, fn {path, text} -> byte_size(path) + byte_size(text) end)) <=
             @max_bytes do
        evidence
      else
        unavailable()
      end
    else
      _ -> unavailable()
    end
  end

  defp read(repo, path) do
    relative = "#{@package}/#{path}"

    with {:ok, %{type: :regular, size: size}} <- File.stat(Path.join(repo, relative)),
         true <- size <= @max_file_bytes,
         {:ok, text} <- Files.read(repo, relative),
         true <- byte_size(text) <= @max_file_bytes and String.valid?(text) do
      {:ok, text}
    else
      _ -> :unavailable
    end
  end

  defp export(text, target) do
    pattern = ~r/^export\s+\*\s+from\s+["']#{Regex.escape(target)}["'];?$/m

    case Regex.run(pattern, text) do
      [line] -> {:ok, line}
      _ -> :unavailable
    end
  end

  defp unavailable do
    [
      {@package,
       "Installed Babylon clamp evidence unavailable: package missing, unsafe, too large, or export/declaration shape unsupported. Verify the installed API before using it."}
    ]
  end
end
