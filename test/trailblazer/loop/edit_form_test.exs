defmodule Trailblazer.Loop.EditFormTest do
  use ExUnit.Case, async: true
  alias Trailblazer.Loop.Tools

  test "an <edit> closing </replace> without opening it is refused with the delete form" do
    # live lucet shape, vortex:c8047e0 (3 dispatches)
    reply = """
    <edit path="v6/hub/store.ts" start="12" end="14">
    <first>export interface StoredMessage {
    <last>  id: string
    }
    </replace>
    </edit>
    """

    assert {:error, msg} = Tools.text_edit_blocks(reply, mode: :text)
    assert msg =~ "v6/hub/store.ts lines 12-14: this <edit> has </replace> but no <replace>"
    assert msg =~ "To delete lines 12-14, leave it empty"
  end

  test "a replace= attribute reply is named, not reported as no edits" do
    reply = ~s(<edit path="v6/client/x.ts" start="1" end="6" replace="\nexport const a = 1\n</edit>\n)
    assert {:error, msg} = Trailblazer.Loop.TextAnswers.edit_blocks(reply, fn _ -> false end)
    assert msg =~ ~s(v6/client/x.ts: replace="..." is not read)
    assert Trailblazer.Loop.TextAnswers.edit_blocks("nothing here", fn _ -> false end) == :none
  end

  test "identical repeated creates of one new file collapse to one; different ones do not" do
    alias Trailblazer.Loop.TextAnswers
    create = ~s(<edit path="n.ts" start="1" end="1">\n<replace>\nexport const a = 1\n</replace>\n</edit>\n)
    assert {:ok, [b]} = TextAnswers.edit_blocks(create <> create <> create, fn _ -> true end)
    assert b.search == ""

    other = String.replace(create, "a = 1", "a = 2")
    assert {:ok, [_, _]} = TextAnswers.edit_blocks(create <> other, fn _ -> true end)

    # the same new file as <edit> creates and written whole: one create
    whole = "n.ts\n```ts\nexport const a = 1\n```\n"
    assert {:ok, [w]} = TextAnswers.answer_blocks(create <> create <> whole, %{"n.ts" => nil})
    assert w.replace =~ "export const a = 1"
  end

  test "a well-formed empty replace still deletes" do
    reply = """
    <edit path="a.ts" start="2" end="3">
    <first>b</first>
    <last>c</last>
    <replace>
    </replace>
    </edit>
    """

    assert {:ok, [%{start: 2, end: 3, replace: ""}]} = Tools.text_edit_blocks(reply, mode: :text)
  end
end
