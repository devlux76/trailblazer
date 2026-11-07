defmodule Trailblazer.Loop.RangedSourceTest do
  use ExUnit.Case, async: true
  alias Trailblazer.Loop.{Prompts, RangedSource}

  # 400 lines: two imports, then a declaration every 50 lines
  defp long_file do
    body =
      for n <- 3..400 do
        if rem(n, 50) == 0, do: "export function f#{n}() {", else: "  x#{n}();"
      end

    ["import { a } from './a'", "import { b } from './b'" | body]
  end

  test "a long file the trail reaches is cut to header, trail ranges and an outline" do
    lines = long_file()
    trail = "src/store.ts:200-210\nexport function f200() {\n\nsrc/other.ts:1-5\nx"

    assert {:ranged, title, body, outline} = RangedSource.cut("src/store.ts", lines, trail)
    assert title =~ "400 lines; showing 1-2, 194-216"
    assert body =~ "1| import { a } from './a'"
    assert body =~ "200| export function f200() {"
    assert body =~ "216|   x216();"
    refute body =~ "217|"
    assert body =~ "… lines 3-193 not shown …"
    assert body =~ "… lines 217-400 not shown …"
    assert outline =~ "50| export function f50() {"
    assert outline =~ "350| export function f350() {"
    refute outline =~ "200| export"
  end

  test "short files and files the trail does not reach stay whole" do
    lines = long_file()
    assert {:whole, ^lines} = RangedSource.cut("src/store.ts", lines, "src/other.ts:1-5\nx")
    assert {:whole, _} = RangedSource.cut("src/store.ts", lines, nil)
    short = Enum.take(lines, 300)
    assert {:whole, _} = RangedSource.cut("src/store.ts", short, "src/store.ts:200-210\nx")
  end

  test "shown lines are capped at max_lines in trail order" do
    lines = long_file()
    trail = Enum.map_join(0..7, "\n\n", &"src/store.ts:#{&1 * 50 + 3}-#{&1 * 50 + 45}\nx")
    {:ranged, _title, body, _} = RangedSource.cut("src/store.ts", lines, trail)
    shown = body |> String.split("\n") |> Enum.count(&Regex.match?(~r/^\d+\| /, &1))
    assert shown == RangedSource.max_lines()
  end

  test "the cap keeps the top-ranked trail range even when it is late in the file" do
    lines = long_file()
    trail = "src/store.ts:380-390\nx\n\nsrc/store.ts:10-370\nx"
    {:ranged, _title, body, _} = RangedSource.cut("src/store.ts", lines, trail)
    assert body =~ "385|"
    assert body =~ "396|"
  end

  test "a whole write of a file too long to have been shown whole is refused" do
    current = %{"src/store.ts" => Enum.join(long_file(), "\n") <> "\n"}
    reply = "src/store.ts\n```ts\nimport { a } from './a'\n```\n"
    assert {:error, msg} = Trailblazer.Loop.TextAnswers.whole_file_blocks(reply, current)
    assert msg =~ "<edit> blocks by line range"
  end

  test "the whole-file coder prompt shows the ranged file in a fence with its outline" do
    text = Enum.join(long_file(), "\n") <> "\n"

    [_system, user] =
      Prompts.coder(%{request: "r", edit_mode: :text}, "src/store.ts:300-301\nx", [{"src/store.ts", 400}], nil, %{
        whole: true,
        sources: [{"src/store.ts", text}]
      })

    assert user.content =~ "src/store.ts (400 lines; showing 1-2, 294-307, real line numbers)\n```typescript\n1| import"
    assert user.content =~ "300| export function f300() {"
    refute user.content =~ "151|"
    assert user.content =~ "Outline of the 400-line file, parts not shown:\n50| export function f50() {"
  end
end
