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
