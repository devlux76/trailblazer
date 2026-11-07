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
end
