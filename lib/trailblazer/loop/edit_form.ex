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
end
