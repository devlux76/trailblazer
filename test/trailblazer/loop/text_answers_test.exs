defmodule Trailblazer.Loop.TextAnswersTest do
  use ExUnit.Case, async: true
  alias Trailblazer.Loop.{Edits, TextAnswers}

  setup do
    dir = Path.join(System.tmp_dir!(), "trailblazer-whole-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write(dir, path, text), do: File.write!(Path.join(dir, path), text)
  defp read(dir, path), do: File.read!(Path.join(dir, path))

  test "path line + fence, or path in the fence info; applied as a diff", %{dir: dir} do
    write(dir, "lib/c.ts", "import a from 'a'\n\nexport const x = 1\n")
    current = TextAnswers.current_files(dir, ["lib/c.ts", "lib/new.ts"])
    assert current["lib/new.ts"] == nil

    reply = """
    Here is the change.

    lib/c.ts
    ```typescript
    import a from 'a'
    import { m } from 'm'

    export const x = m(1)
    ```

    ```ts lib/new.ts
    export const y = 2
    ```
    """

    assert {:ok, [c, n]} = TextAnswers.whole_file_blocks(reply, current)
    assert {c.start, c.end, c.first, c.last} == {1, 3, "import a from 'a'", "export const x = 1"}
    assert n == %{path: "lib/new.ts", search: "", replace: "export const y = 2\n"}
    assert {:ok, _} = Edits.apply(dir, [c, n])

    assert read(dir, "lib/c.ts") ==
             "import a from 'a'\nimport { m } from 'm'\n\nexport const x = m(1)\n"

    assert read(dir, "lib/new.ts") == "export const y = 2\n"
  end

  test "markdown heading path; unknown paths ignored; placeholders refused" do
    current = %{"src/core/contact.ts" => "a\nb\nc\n"}

    assert {:ok, [b]} =
             TextAnswers.whole_file_blocks(
               "### `src/core/contact.ts`\n```typescript\na\nB\nc\n```\n",
               current
             )

    assert b.replace == "a\nB\nc\n"
    assert TextAnswers.whole_file_blocks("other.ts\n```ts\nx\n```\n", current) == :none
    assert TextAnswers.whole_file_blocks("no files here", current) == :none

    assert {:error, msg} =
             TextAnswers.whole_file_blocks(
               "src/core/contact.ts\n```ts\na\n// ... rest unchanged\n```\n",
               current
             )

    assert msg =~ "placeholder"
  end

  test "usages: the repository's own import line for a named package", %{dir: dir} do
    write(dir, "lib/n.ts", "import { multiaddr } from '@multiformats/multiaddr'\n")
    System.cmd("git", ["init", "-q", dir])
    System.cmd("git", ["-C", dir, "add", "."])

    assert TextAnswers.usages(dir, %{request: "use @multiformats/multiaddr", design: nil}) ==
             "import { multiaddr } from '@multiformats/multiaddr'"

    assert TextAnswers.usages(dir, %{request: "no package", design: nil}) == nil
  end

  test "live lucet: the whole file through its own write tool call" do
    current = %{"src/core/contact.test.ts" => "a\nb\n"}

    reply =
      "<tool_call>write<arg_key>path</arg_key><arg_value>src/core/contact.test.ts</arg_value>" <>
        "<arg_key>content</arg_key><arg_value>a\nb\nc\n</arg_value></tool_call>"

    assert {:ok, [b]} = TextAnswers.whole_file_blocks(reply, current)
    assert {b.path, b.start, b.end, b.replace} == {"src/core/contact.test.ts", 1, 2, "a\nb\nc\n"}
    # a path it was not given is ignored
    assert TextAnswers.whole_file_blocks(String.replace(reply, "contact.test", "other"), current) ==
             :none
  end

  test "changed_files: complete text of each file a diff touches", %{dir: dir} do
    write(dir, "lib/c.ts", "x\n")
    diff = "--- a/lib/c.ts\n+++ b/lib/c.ts\n@@\n+x\n--- a/gone.ts\n+++ b/gone.ts\n"
    assert TextAnswers.changed_files(dir, diff) == [{"lib/c.ts", "x\n"}]
  end
end
