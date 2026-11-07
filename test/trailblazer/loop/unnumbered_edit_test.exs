defmodule Trailblazer.Loop.UnnumberedEditTest do
  use ExUnit.Case, async: true
  alias Trailblazer.Loop.TextAnswers

  setup do
    dir = Path.join(System.tmp_dir!(), "unnum-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "server.ts"), Enum.map_join(1..90, "", &"line #{&1}\n"))
    File.write!(Path.join(dir, "long.ts"), Enum.map_join(1..200, "", &"line #{&1}\n"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  @guess ~s(<edit path="server.ts" start="29" end="38">\n<replace>\nx\n</replace>\n</edit>\n)

  test "whole mode: an unquoted range on a file shown without numbers is refused", %{dir: dir} do
    assert {:error, msg} = TextAnswers.edit_blocks(@guess, {dir, ["server.ts"], true})
    assert msg =~ "server.ts was shown whole without line numbers, so start=29 end=38 is a guess"
  end

  test "quoted ranges, numbered (long) files and non-whole mode still pass", %{dir: dir} do
    quoted =
      ~s(<edit path="server.ts" start="29" end="29">\n<first>line 29</first>\n<last>line 29</last>\n<replace>\nx\n</replace>\n</edit>\n)

    assert {:ok, [_]} = TextAnswers.edit_blocks(quoted, {dir, ["server.ts"], true})
    long = String.replace(@guess, "server.ts", "long.ts")
    assert {:ok, [_]} = TextAnswers.edit_blocks(long, {dir, ["long.ts"], true})
    assert {:ok, [_]} = TextAnswers.edit_blocks(@guess, {dir, ["server.ts"], false})
    # a file the task did not name may have been read numbered
    assert {:ok, [_]} = TextAnswers.edit_blocks(@guess, {dir, ["other.ts"], true})
    # 150 lines + a trailing blank line = 151 as the prompt counts: numbered
    File.write!(Path.join(dir, "server.ts"), Enum.map_join(1..150, "", &"l#{&1}\n") <> "\n")
    assert {:ok, [_]} = TextAnswers.edit_blocks(@guess, {dir, ["server.ts"], true})
  end
end
