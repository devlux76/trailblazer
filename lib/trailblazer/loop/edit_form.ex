defmodule Trailblazer.Loop.EditForm do
  @moduledoc """
  Plain-spoken refusals for `<edit>` blocks in a shape the parser cannot use.

  lucet wrote a deletion as `<first>line<last>every line of the range</replace>`
  with no `<replace>` opening, three dispatches running (live, vortex:c8047e0,
  2026-11-07); the generic error ("lines that start with edit tags") never
  told it what was missing, so it repeated the shape. Guessing the intent is
  unsafe (one such block named only a class header line), so it is refused
  with the exact form to use.
  """

  @doc "nil when the body has no known misshape, else `{:error, message}`."
  def check(body, path, attrs) do
    if body =~ ~r/<\/replace>/ and not (body =~ ~r/<replace>/) do
      range = "#{attrs["start"] || "?"}-#{attrs["end"] || "?"}"

      {:error,
       "#{path} lines #{range}: this <edit> has </replace> but no <replace>. " <>
         "<first> and <last> each hold ONE line (lines #{attrs["start"]} and #{attrs["end"]}), " <>
         "each closed by </first> and </last>; the new lines go between <replace> and </replace>. " <>
         "To delete lines #{range}, leave it empty: <replace>\n</replace>"}
    end
  end

  @doc """
  For a reply in which no edit block was found: nil, or `{:error, message}`
  naming a known unreadable shape. lucet put the new text in a `replace="..."`
  attribute (live, vortex:85be62a attempt 2), so the opening tag never closed
  on its line and the reply read as "no edits" with no hint why.
  """
  def unread(text) do
    case Regex.run(~r/<edit\b[^>\n]*\bpath="([^"]*)"[^>\n]*\breplace="/, text) do
      [_, path] ->
        {:error,
         "#{path}: replace=\"...\" is not read. Put the new lines between <replace> and </replace> " <>
           "inside the block, after its <first>...</first> and <last>...</last> lines; " <>
           "a file shown without line numbers is written out complete instead"}

      _ ->
        nil
    end
  end
end
