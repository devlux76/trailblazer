defmodule Trailblazer.Loop.Context do
  @moduledoc "What the coder and the head start read: named-file sources, the test pattern and prompt sizes."

  alias Trailblazer.Files
  import Trailblazer.Loop.Ledger, only: [tracked: 1]

  # Text mode sends named files whole (long ones numbered, edited by range) up
  # to 1000 lines/64 KB; past that name-only (a 619-line file at 400, read rounds 0: unseen).
  @source_lines 1000

  @source_bytes 64_000

  @doc false
  def sources(st) do
    st.task.files
    |> Enum.flat_map(fn path ->
      case Files.read(st.ws.path, path) do
        # binary (non-UTF-8) files never go in: they would break the JSON request
        {:ok, text} ->
          if String.valid?(text) and lines(text) <= @source_lines, do: [{path, text}], else: []

        {:error, _} ->
          []
      end
    end)
    |> Enum.reduce({[], 0}, fn {_, text} = file, {kept, used} ->
      if used + byte_size(text) <= @source_bytes,
        do: {[file | kept], used + byte_size(text)},
        else: {kept, used}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc false
  def lines(""), do: 0

  def lines(text), do: length(String.split(String.trim_trailing(text, "\n"), "\n"))

  # The head start's test to follow (design §6.5): when the request asks for
  # a test and no file the caller named is one, the test of a named file, or
  # else the repository's smallest test as its conventions, within 6 KB.
  @test_path ~r{(^|/)(tests?|spec|__tests__)/|[._-](test|spec)\.[a-z]+$|_test\.exs?$|(^|/)test_[^/]+\.py$}

  @pattern_bytes 6_000

  @doc false
  def pattern(st) do
    named = st.task.files

    if Regex.match?(~r/\btests?\b/i, st.task.request) and
         not Enum.any?(named, &Regex.match?(@test_path, &1)) do
      stems = MapSet.new(named, &stem/1)
      tests = st.ws.path |> tracked() |> Enum.filter(&Regex.match?(@test_path, &1))

      candidates =
        case Enum.filter(tests, &MapSet.member?(stems, stem(&1))) do
          [] -> Enum.sort_by(tests, &file_size(st.ws.path, &1))
          own -> own
        end

      Enum.find_value(candidates, fn path ->
        case Files.read(st.ws.path, path) do
          {:ok, text} when byte_size(text) <= @pattern_bytes -> {path, text}
          _ -> nil
        end
      end)
    end
  end

  # The coder prompt's bytes by section, so budgets are tuned against the
  # record (design §6.5.4): %{"system" => n, "Trail" => n, ...}.
  @doc false
  def prompt_sizes([%{content: system}, %{content: user}]) do
    user
    |> String.split(~r/^## /m)
    |> Enum.reject(&(&1 == ""))
    |> Map.new(fn part -> {part |> String.split("\n", parts: 2) |> hd(), byte_size(part)} end)
    |> Map.put("system", byte_size(system))
  end

  def prompt_sizes(messages), do: %{"total" => messages |> inspect() |> byte_size()}

  defp stem(path) do
    path
    |> Path.basename()
    |> String.replace(~r/^test_|([._-](test|spec))?(\.[a-z0-9]+)+$|_test$/i, "")
    |> String.downcase()
  end

  defp file_size(root, path) do
    case File.stat(Path.join(root, path)) do
      {:ok, %{size: size}} -> size
      _ -> :infinity
    end
  end
end
