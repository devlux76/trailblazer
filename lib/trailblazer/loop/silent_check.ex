defmodule Trailblazer.Loop.SilentCheck do
  @moduledoc """
  A failed check that printed nothing gives the coder nothing to learn from
  (live, vortex:c8047e0 attempt 2: `test $(wc -l < store.ts) -le 640 && ...`
  failed silently; the retry was told only "failed"). For such a result the
  check's `test` / `[` steps are re-run alone under `sh -x` (shell builtins,
  instant), and the first that fails is named with its expanded form, e.g.
  `+ test 766 -le 640`.
  """

  @step ~r/^\s*(?:test|\[)\s/

  @doc "`result` with an explanation in place of blank output on a failure."
  def annotate(%{status: :fail, output_tail: tail} = result, path, command)
      when is_binary(path) and is_binary(command) do
    if String.trim(tail || "") == "",
      do: %{result | output_tail: explain(path, command)},
      else: result
  end

  def annotate(result, _path, _command), do: result

  defp explain(path, command) do
    failed =
      command
      |> String.split(~r/\s*&&\s*/)
      |> Enum.filter(&Regex.match?(@step, &1))
      |> Enum.find_value(fn step ->
        case System.cmd("sh", ["-xc", step], cd: path, stderr_to_stdout: true) do
          {_, 0} -> nil
          {trace, _} -> {step, String.trim(trace)}
        end
      end)

    case failed do
      nil ->
        "(the check printed nothing; exit status non-zero)"

      {step, trace} ->
        "(the check printed nothing) This step failed: `#{step}`, evaluated as:\n#{trace}"
    end
  rescue
    _ -> "(the check printed nothing; exit status non-zero)"
  end
end
