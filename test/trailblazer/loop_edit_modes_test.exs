defmodule Trailblazer.LoopTest.EditModes do
  use ExUnit.Case, async: false

  alias Trailblazer.Loop

  defmodule Script do
    def chat(messages, opts) do
      send(Process.get(:loop_test), {:asked, messages, opts})

      case Process.get(:script, []) do
        [next | rest] ->
          Process.put(:script, rest)
          if is_function(next), do: next.(messages, opts), else: next

        [] ->
          raise "the script ran out"
      end
    end
  end

  @greeting """
  defmodule Greeting do
    def hello(name), do: "Hello " <> name
  end
  """

  setup do
    repo = Path.join(System.tmp_dir!(), "trailblazer-loop-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(repo, "lib"))
    File.write!(Path.join(repo, "lib/greeting.ex"), @greeting)
    git(repo, ["init", "-q", "-b", "main"])
    git(repo, ["add", "."])
    git(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"])
    on_exit(fn -> File.rm_rf!(repo) end)
    Process.put(:loop_test, self())

    opts = [
      model: Script,
      trail: fn _repo, _request, _opts ->
        %{text: "lib/greeting.ex:1-3\n  def hello(name)", notes: []}
      end,
      gate: false,
      checkpoint_opts: [command: fn _, _ -> {~s({"ref":"fixture:abcdef1"}), 0} end]
    ]

    %{repo: repo, opts: opts}
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  defp script(replies), do: Process.put(:script, replies)

  defp reply(content, extra \\ %{}) do
    {:ok,
     Map.merge(
       %{
         content: content,
         reasoning: "thinking",
         tool_calls: [],
         usage: %{prompt_tokens: 100, completion_tokens: 10},
         ms: 5,
         finish_reason: "stop"
       },
       extra
     )}
  end

  @fix_tags """
  Add a comma after Hello.

  <edit path="lib/greeting.ex" start="2" end="2">
  <first>  def hello(name), do: "Hello " <> name</first>
  <last>  def hello(name), do: "Hello " <> name</last>
  <replace>
    def hello(name), do: "Hello, " <> name
  </replace>
  </edit>
  """

  @check "grep -q 'Hello, ' lib/greeting.ex"

  # A retry continues from the previous attempt's edits, so corrections are
  # made against them (not against the original file).

  defp task(repo, extra),
    do:
      Map.merge(
        %{repo: repo, request: "Greet with a comma", files: ["lib/greeting.ex"], check: @check},
        extra
      )

  defp submitted(blocks) do
    reply("", %{
      tool_calls: [
        %{id: "edit1", name: "submit_edits", arguments: Jason.encode!(%{blocks: blocks})}
      ]
    })
  end

  defp greeting_block do
    %{
      path: "lib/greeting.ex",
      search: ~s|  def hello(name), do: "Hello " <> name\n|,
      replace: ~s|  def hello(name), do: "Hello, " <> name\n|
    }
  end

  # Recall runs in a job of its own, so the test's pid is found globally.

  test "several flat edit calls form one batch with code as plain strings", %{
    repo: repo,
    opts: opts
  } do
    edits = fn _messages, options ->
      assert "edit" in Enum.map(options[:tools], & &1.function.name)

      reply("", %{
        tool_calls: [
          %{
            id: "e1",
            name: "edit",
            arguments:
              Jason.encode!(%{
                path: "lib/greeting.ex",
                search: ~s|  def hello(name), do: "Hello " <> name\n|,
                replace: ~s|  def hello(name), do: "Hello, " <> name\n|
              })
          },
          %{
            id: "e2",
            name: "edit",
            arguments:
              Jason.encode!(%{
                path: "lib/greeting.ex",
                search: "defmodule Greeting do\n",
                replace: "defmodule Greeting do\n  @moduledoc false\n"
              })
          }
        ]
      })
    end

    script([edits, reply("PASS")])
    report = Loop.run(task(repo, %{read_rounds: 0}), opts)
    assert report.status == :fixed
    file = git(repo, ["show", "#{report.commit}:lib/greeting.ex"])
    assert file =~ "Hello, "
    assert file =~ "@moduledoc false"
  end

  test "one bad flat edit refuses the whole batch and is corrected", %{repo: repo, opts: opts} do
    bad = fn _messages, _ ->
      reply("", %{
        tool_calls: [
          %{
            id: "e1",
            name: "edit",
            arguments: Jason.encode!(%{path: "lib/greeting.ex", search: "x"})
          },
          %{id: "e2", name: "edit", arguments: Jason.encode!(greeting_block())}
        ]
      })
    end

    fixed = fn messages, _ ->
      answers = Enum.filter(messages, &(&1.role == "tool"))
      assert length(answers) == 2
      assert hd(answers).content =~ "edit:"

      reply("", %{
        tool_calls: [%{id: "e3", name: "edit", arguments: Jason.encode!(greeting_block())}]
      })
    end

    script([bad, fixed, reply("PASS")])
    assert Loop.run(task(repo, %{read_rounds: 0}), opts).status == :fixed
  end

  test "text mode answers an unoffered flat edit call like an unknown tool", %{
    repo: repo,
    opts: opts
  } do
    rogue = fn _messages, _ ->
      reply("", %{
        tool_calls: [%{id: "e1", name: "edit", arguments: Jason.encode!(greeting_block())}]
      })
    end

    final = fn messages, options ->
      refute options[:tools]
      assert Enum.find(messages, &(&1.role == "tool")).content =~ "no edit tool in this mode"
      reply(@fix_tags)
    end

    script([rogue, final, reply("PASS")])
    assert Loop.run(task(repo, %{read_rounds: 1, edit_mode: :text}), opts).status == :fixed
  end

  test "an invalid edit_mode is refused", %{repo: repo, opts: opts} do
    assert_raise ArgumentError, ~r/edit_mode/, fn ->
      Loop.run(task(repo, %{edit_mode: "json"}), opts)
    end
  end

  test "a relocated range is reported in the next attempt's feedback", %{
    repo: repo,
    opts: opts
  } do
    digest = :crypto.hash(:sha256, @greeting) |> Base.encode16(case: :lower)
    line2 = ~s|  def hello(name), do: "Hello " <> name|

    block = fn start, replace ->
      %{
        path: "lib/greeting.ex",
        sha256: digest,
        start: start,
        end: 2,
        first: line2,
        last: line2,
        replace: replace
      }
    end

    # Off by one (start 1): relocated to 2-2, written, but fails the check.
    first = fn _messages, _ ->
      submitted([block.(1, ~s|  def hello(name), do: "Hi " <> name\n|)])
    end

    second = fn messages, _ ->
      assert Enum.any?(
               messages,
               &(&1.content =~ "range 1-2 in lib/greeting.ex was applied as lines 2-2")
             )

      # the relocated edit is still applied: correct it, not the original
      submitted([
        %{
          path: "lib/greeting.ex",
          search: ~s|  def hello(name), do: "Hi " <> name\n|,
          replace: ~s|  def hello(name), do: "Hello, " <> name\n|
        }
      ])
    end

    script([first, second, reply("PASS")])
    report = Loop.run(task(repo, %{read_rounds: 0}), opts)
    assert report.status == :fixed
    assert report.attempts == 2
    assert git(repo, ["show", "#{report.commit}:lib/greeting.ex"]) =~ ~s|"Hello, "|
  end

  test "native ranges use the digest delivered by read without recopying source", %{
    repo: repo,
    opts: opts
  } do
    read =
      reply("", %{
        tool_calls: [%{id: "read-hash", name: "read", arguments: ~s({"path":"lib/greeting.ex"})}]
      })

    submit = fn messages, options ->
      assert options[:tool_choice] == "required"

      assert options[:tools] ==
               [
                 Trailblazer.Loop.Tools.edit_definition(:ranges),
                 Trailblazer.Loop.Tools.flat_edit_definition()
               ]

      digest = :crypto.hash(:sha256, @greeting) |> Base.encode16(case: :lower)

      assert Enum.find(Enum.reverse(messages), &(&1.role == "tool")).content =~
               "sha256: #{digest}"

      submitted([
        %{
          path: "lib/greeting.ex",
          sha256: digest,
          start: 2,
          end: 2,
          first: ~s|  def hello(name), do: "Hello " <> name|,
          last: ~s|def hello(name), do: "Hello " <> name|,
          replace: ~s|  def hello(name), do: "Hello, " <> name\n|
        }
      ])
    end

    script([read, submit, reply("PASS")])
    report = Loop.run(task(repo, %{read_rounds: 1}), opts)
    assert report.status == :fixed
    assert report.attempts == 1
    assert git(repo, ["show", "#{report.commit}:lib/greeting.ex"]) =~ "Hello, "
  end

  test "whole-file append misuse is corrected locally to a digest-bound replacement", %{
    repo: repo,
    opts: opts
  } do
    replacement = String.replace(@greeting, "Hello ", "Hello, ")

    correction = fn messages, _ ->
      feedback = List.last(messages)
      assert feedback.role == "tool"
      assert feedback.content =~ "file_exists"
      hash = :crypto.hash(:sha256, @greeting) |> Base.encode16(case: :lower)
      assert feedback.content =~ hash

      submitted([
        %{
          path: "lib/greeting.ex",
          sha256: hash,
          start: 1,
          end: 3,
          first: @greeting |> String.split("\n") |> Enum.at(0),
          last: @greeting |> String.split("\n") |> Enum.at(2),
          replace: replacement
        }
      ])
    end

    script([
      submitted([%{path: "lib/greeting.ex", search: "", replace: replacement}]),
      correction,
      reply("PASS")
    ])

    report = Loop.run(task(repo, %{read_rounds: 0}), opts)
    assert report.status == :fixed
    assert report.attempts == 1
    assert report.cost.model_calls == 3
    assert git(repo, ["show", "#{report.commit}:lib/greeting.ex"]) == replacement
  end

  test "existing named files with read rounds advertise an unambiguous range schema", %{
    repo: repo,
    opts: opts
  } do
    first = fn _messages, options ->
      items =
        Enum.find(options[:tools], &(&1.function.name == "submit_edits")).function.parameters.properties.blocks.items

      refute Map.has_key?(items, :anyOf)
      assert "sha256" in items.required
      submitted([greeting_block()])
    end

    script([first, reply("PASS")])
    assert Loop.run(task(repo, %{read_rounds: 1}), opts).status == :fixed
  end

  test "zero-read and new-file tasks keep the compatible dual schema", %{repo: repo, opts: opts} do
    for extra <- [%{read_rounds: 0}, %{files: ["lib/greeting.ex", "notes.txt"], read_rounds: 1}] do
      first = fn _messages, options ->
        items =
          Enum.find(options[:tools], &(&1.function.name == "submit_edits")).function.parameters.properties.blocks.items

        assert length(items.anyOf) == 2
        submitted([greeting_block()])
      end

      script([first, reply("PASS")])
      assert Loop.run(task(repo, extra), opts).status == :fixed
    end
  end
end
