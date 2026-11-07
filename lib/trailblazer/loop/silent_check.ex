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

  @generic "(the check printed nothing; exit status non-zero)"
  @trace_max 2_000

  defp explain(path, command) do
    steps = String.split(command, ~r/\s*&&\s*/)

    # a step after a `cd` would run elsewhere than in the real check
    failed =
      if Enum.any?(steps, &Regex.match?(~r/(^|\s)(cd|pushd)\s/, &1)),
        do: nil,
        else: steps |> Enum.filter(&Regex.match?(@step, &1)) |> Enum.find_value(&probe(path, &1))

    case failed do
      nil ->
        @generic

      {step, trace} ->
        "(the check printed nothing) This step failed: `#{step}`, evaluated as:\n" <>
          String.slice(trace, -@trace_max, @trace_max)
    end
  rescue
    _ -> @generic
  end

  # bounded (5 s) and with no stdin, so a step that reads or sleeps cannot
  # hold the caller
  defp probe(path, step) do
    case System.cmd("sh", ["-c", "timeout 5 sh -xc \"$1\" </dev/null", "probe", step],
           cd: path,
           stderr_to_stdout: true
         ) do
      {_, 0} -> nil
      {trace, _} -> {step, String.trim(trace)}
    end
  end
end
