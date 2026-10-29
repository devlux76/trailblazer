defmodule Trailblazer.Planner.Route do
  @moduledoc """
  The deterministic part of the routing decision (trailblazer:4cc63df): a card
  goes to a supervised coder when its body names the files to change and states
  acceptance criteria (a test or check to pass) plus an Implementation plan, and it is not labelled
  `dispatch:research`. A body with neither marker is a research card; exactly
  one marker is the tie only the model decides.

  Without an implementation plan it always goes to research, even if the model
  selected the coding target. A marker proves presence, not plan quality.

  The file and acceptance markers are two lines, `Files:` with the repo-relative paths (separated
  by commas or spaces) and `Acceptance:` with the criteria on that line. The
  parse never reads the filesystem: naming is a writing convention, verified
  by the card's own check later, not here.
  """
  @path ~r/\A[A-Za-z0-9_.\-][A-Za-z0-9_.\-]*\/?[A-Za-z0-9_.\-]*\.[A-Za-z0-9_]{1,10}\z/

  @spec classify(map()) :: :trailblazer | :research | :tie
  def classify(context) when is_map(context) do
    if "dispatch:research" in List.wrap(context["labels"]) do
      :research
    else
      body = context["body"]
      files? = ok_files?(body)
      acceptance? = ok_acceptance?(body)

      cond do
        not ok_plan?(body) -> :research
        files? and acceptance? -> :trailblazer
        files? or acceptance? -> :tie
        true -> :research
      end
    end
  end

  def classify(_), do: :research

  defp ok_plan?(body), do: is_binary(body) and marker(body, "Implementation plan:") not in [nil, ""]

  defp ok_files?(body), do: match?({:ok, [_ | _]}, parse_files(body))
  defp ok_acceptance?(body), do: match?({:ok, text} when text != "", parse_acceptance(body))

  @doc "The paths on the first `Files:` line, or `:error` when none parse."
  def parse_files(body) when is_binary(body) do
    case marker(body, "Files:") do
      nil -> :error
      text -> files(text)
    end
  end

  def parse_files(_), do: :error

  @doc "The first `Acceptance:` line's criteria, or `:error` when empty or missing."
  def parse_acceptance(body) when is_binary(body) do
    case marker(body, "Acceptance:") do
      nil -> :error
      text -> acceptance(text)
    end
  end

  def parse_acceptance(_), do: :error

  # The first line that starts with the marker; a line that only mentions a
  # marker mid-paragraph is not the marker.
  defp marker(body, prefix) do
    body
    |> String.split(["\r\n", "\n"])
    |> Enum.find_value(fn line ->
      if String.starts_with?(line, prefix),
        do: String.trim_leading(line, prefix) |> String.trim_trailing() |> String.trim_leading(),
        else: nil
    end)
  end

  defp files(""), do: :error

  defp files(text) do
    paths =
      text
      |> String.split([",", " ", "\t"])
      |> Enum.reject(&(&1 == ""))

    if paths != [] and Enum.all?(paths, &file?/1), do: {:ok, paths}, else: :error
  end

  defp file?(path) do
    body = Path.basename(path)

    Regex.match?(@path, body) and Path.type(path) == :relative and
      not String.contains?(path, "..") and not String.contains?(path, " ")
  end

  defp acceptance(""), do: :error
  defp acceptance(text), do: {:ok, text}
end
