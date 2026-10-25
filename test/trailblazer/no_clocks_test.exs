defmodule Trailblazer.NoClocksTest do
  # Design §13.2: no clock moves Trailblazer's work. Waits are for messages;
  # the only timer is the Backstop's. This keeps clocks from creeping back.
  use ExUnit.Case, async: true

  @clock ~r/Process\.sleep\(|Process\.send_after\(|:timer\.(sleep|send_after|send_interval|apply_after)|receive_timeout: [0-9@]|\btimeout: [0-9@]|@\w*timeout\w* [0-9]|after (?!0 ->)[0-9@][\w]* ->/

  # Files allowed a clock, and why. Permanent entries first; the rest are the
  # phase 2b tasks that remove them, and each entry is deleted when its task
  # lands (a clean file still listed fails below).
  @allowed %{
    "lib/trailblazer/backstop.ex" => "the one timer: backstops (design §13.5)",
    "lib/trailblazer/model.ex" =>
      "retry while the router loads the model, under the call's backstop (§13.6)",
    "lib/trailblazer/embed_health.ex" =>
      "probe retry while work waits: the router announces no readiness (design §13.4)"
  }

  defp clocks do
    for path <- Path.wildcard("lib/**/*.ex"),
        {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        not String.starts_with?(String.trim_leading(line), "#"),
        Regex.match?(@clock, line),
        do: {path, n, String.trim(line)}
  end

  test "no clock in lib/ outside the allowed files" do
    stray = Enum.reject(clocks(), fn {path, _, _} -> Map.has_key?(@allowed, path) end)
    assert stray == [], "clocks outside the allowed files: #{inspect(stray, pretty: true)}"
  end

  test "every allowed file still needs its entry" do
    with_clocks = clocks() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    stale = @allowed |> Map.keys() |> Enum.reject(&MapSet.member?(with_clocks, &1))
    assert stale == [], "no clock left in #{inspect(stale)}: delete their entries"
  end
end
