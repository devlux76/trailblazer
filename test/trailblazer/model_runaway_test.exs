defmodule Trailblazer.ModelRunawayTest do
  use ExUnit.Case, async: true
  alias Trailblazer.Model.Runaway

  @answer "<edit path=\"a.ts\" start=\"1\" end=\"1\">\n<replace>\nx\n</replace>\n</edit>\n"

  test "a line repeated 40 times ends the reply; the answer before it is kept" do
    content = @answer <> String.duplicate("</fenced>\n", 45)
    assert {:runaway, kept} = Runaway.trim(content)
    assert kept == @answer
  end

  test "short repeats, blank runs and normal code are left alone" do
    assert Runaway.trim(@answer <> String.duplicate("</fenced>\n", 30)) == :ok
    assert Runaway.trim(@answer <> String.duplicate("\n", 50)) == :ok
    assert Runaway.trim(Enum.map_join(1..100, "\n", &"line #{&1}")) == :ok
  end

  test "a long reply is checked by its tail only" do
    content = String.duplicate("y\n", 10_000) <> @answer <> String.duplicate("}\n", 41)
    assert {:runaway, kept} = Runaway.trim(content)
    assert String.ends_with?(kept, @answer)
  end

  test "the numbered view copied back (8 consecutive N| lines) stops the reply before the copy" do
    copy = Enum.map_join(140..148, "", &"#{&1}|   line #{&1}\n")
    content = @answer <> "v6/cli/vx.ts\n```typescript\n" <> copy
    assert {:runaway, kept} = Runaway.trim(content)
    assert kept == @answer <> "v6/cli/vx.ts\n```typescript\n"
    # 7 numbered lines, or numbers that do not run consecutively, are left alone
    assert Runaway.trim(@answer <> Enum.map_join(1..7, "", &"#{&1}| x\n")) == :ok
    assert Runaway.trim(@answer <> Enum.map_join(1..8, "", &"#{&1 * 2}| x\n")) == :ok
  end
end
