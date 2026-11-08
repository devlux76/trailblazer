defmodule Trailblazer.Loop.Tools do
  @moduledoc """
  The core's questions (design §6.7) as tools the code model may call during
  an attempt, when the trail is not enough: `where`, `uses`, `impact`, `read`
  and `search`.

  Answers are compact text, one line per item, capped at #{12_000}
  characters, because they go into a 65k-token context. A model's call is
  untrusted data (D4): an unknown tool, arguments that are not JSON or have
  the wrong shape, a path outside the repository and a question the core
  cannot answer all come back as a line starting with `error:`, never as an
  exception.

  The graph answers about the watched repository. `read` reads from the
  task's worktree when one is given (`%{repo: path, worktree: path}`), since
  that is the text the model's edits must match. Its answer starts with a
  compact path/sha256/lines header: the sha256 identifies the exact bytes the
  model may edit with a range block.
  """
  alias Trailblazer.Loop.Tools.Blocks
  alias Trailblazer.Loop.Tools.Native
  alias Trailblazer.Loop.Tools.Questions
  alias Trailblazer.Loop.Tools.Tags

  @names ~w(where uses impact read search)
  # An <edit ...> or <create ...> opening tag at the start of a line (a tag
  # mentioned inside a sentence is not one).
  @native_open "<|tool_call_start|>"
  @argkey_call ~r/<tool_call>\s*(?:edit|submit_edits)\b[^\n]*?(?:<arg_key>|<arg_value>|\w+\s*=\s*")/
  @tag_open ~r/^[ \t]*<(edit|create)\b([^>\n]*)>/m

  @doc """
  Strict whole-message JSON fallback; code bytes and edit validation stay unchanged.

  With `mode: :text` (the plain-text coder) a reply holding `<edit>`/`<create>`
  tags is read as tags (code raw, see below); otherwise its JSON is read in the
  text dialect of `edit_blocks/2`, and may follow a sentence or two in one
  ```json fence.
  """
  def text_edit_blocks(text, opts \\ []) when is_binary(text) do
    text_mode? = Keyword.get(opts, :mode) == :text

    cond do
      text_mode? and not Regex.match?(@tag_open, text) and String.contains?(text, @native_open) ->
        Native.native_edit_blocks(text)

      text_mode? and not Regex.match?(@tag_open, text) and Regex.match?(@argkey_call, text) ->
        Native.argkey_edit_blocks(text)

      true ->
        tag_or_json_blocks(text, opts, text_mode?)
    end
  end

  defp tag_or_json_blocks(text, opts, text_mode?) do
    if text_mode? and Regex.match?(@tag_open, text) do
      case Tags.tag_blocks(text) do
        {:ok, _} = ok ->
          ok

        # a reply that only mentions a tag may still carry JSON
        {:error, message} ->
          case Blocks.json_edit_blocks(text, opts) do
            {:ok, _} = ok -> ok
            _ -> {:error, message}
          end
      end
    else
      Blocks.json_edit_blocks(text, opts)
    end
  end

  @doc """
  Answers one tool call. `arguments` is the JSON text the model sent, or an
  already decoded map. `opts` go to `Trailblazer.Query`.
  """
  @spec call(
          Path.t() | %{repo: Path.t(), worktree: Path.t() | nil},
          String.t(),
          String.t() | map(),
          keyword()
        ) ::
          String.t()
  def call(target, name, arguments, opts \\ [])

  def call(repo, name, arguments, opts) when is_binary(repo),
    do: call(%{repo: repo, worktree: nil}, name, arguments, opts)

  def call(%{repo: _} = target, name, arguments, opts) do
    with :ok <- known(name),
         {:ok, args} <- Blocks.decode(arguments) do
      name |> Questions.answer(target, args, opts) |> Questions.capped()
    else
      {:error, message} -> "error: " <> message
    end
  rescue
    e -> "error: #{name} failed: #{Exception.message(e)}"
  catch
    kind, reason -> "error: #{name} failed: #{inspect({kind, reason})}"
  end

  @doc """
  One attempt's reads, deduplicated: `served` maps `{path, sha256}` to the line
  numbers already shown. A read whose numbered lines were all shown before
  (same file bytes) becomes a one-line pointer, so a model that loops on
  re-reading does not pay the whole prompt again for nothing (on CPU each
  re-read cost minutes of prefill and expired the window). New lines, a
  changed file and anything not a read pass through. Returns `{text, served}`.
  """
  @spec dedupe_read(String.t(), map()) :: {String.t(), map()}
  def dedupe_read(text, served) when is_binary(text) and is_map(served) do
    with [_, path] <- Regex.run(~r/^path: (.+)$/m, text),
         [_, sha] <- Regex.run(~r/^sha256: ([0-9a-f]+)$/m, text),
         [_ | _] = shown <- shown_lines(text) do
      key = {path, sha}
      seen = Map.get(served, key, MapSet.new())

      if Enum.all?(shown, &MapSet.member?(seen, &1)) do
        {first, last} = Enum.min_max(shown)

        {"path: #{path}\nsha256: #{sha}\n#{path} lines #{first}-#{last} are unchanged and already shown above in this attempt; do not read them again. Use what you have and reply with your edits now.",
         served}
      else
        {text, Map.put(served, key, Enum.into(shown, seen))}
      end
    else
      _ -> {text, served}
    end
  end

  def dedupe_read(text, served), do: {text, served}

  defp shown_lines(text) do
    for [_, n] <- Regex.scan(~r/^(\d+)\| /m, text), do: String.to_integer(n)
  end

  defp known(name) when name in @names, do: :ok

  defp known(name),
    do:
      {:error,
       "no tool named #{inspect(to_string(name))}; the tools are #{Enum.join(@names, ", ")}"}

  @doc delegate_to: {Trailblazer.Loop.Tools.Questions, :cap, 0}
  defdelegate cap(), to: Trailblazer.Loop.Tools.Questions

  @doc delegate_to: {Trailblazer.Loop.Tools.Definitions, :definitions, 0}
  defdelegate definitions(), to: Trailblazer.Loop.Tools.Definitions

  @doc delegate_to: {Trailblazer.Loop.Tools.Definitions, :edit_definition, 1}
  defdelegate edit_definition(mode \\ :both), to: Trailblazer.Loop.Tools.Definitions

  @doc delegate_to: {Trailblazer.Loop.Tools.Definitions, :edit_tools, 0}
  defdelegate edit_tools(), to: Trailblazer.Loop.Tools.Definitions

  @doc delegate_to: {Trailblazer.Loop.Tools.Definitions, :flat_edit_definition, 0}
  defdelegate flat_edit_definition(), to: Trailblazer.Loop.Tools.Definitions

  @doc delegate_to: {Trailblazer.Loop.Tools.Blocks, :edit_call_blocks, 2}
  defdelegate edit_call_blocks(name, arguments), to: Trailblazer.Loop.Tools.Blocks

  @doc delegate_to: {Trailblazer.Loop.Tools.Blocks, :edit_blocks, 2}
  defdelegate edit_blocks(arguments, opts \\ []), to: Trailblazer.Loop.Tools.Blocks

  @doc false
  defdelegate native_edit_blocks(text), to: Trailblazer.Loop.Tools.Native

  @doc delegate_to: {Trailblazer.Loop.Tools.Native, :native_call_blocks, 1}
  defdelegate native_call_blocks(arguments), to: Trailblazer.Loop.Tools.Native

  @doc false
  defdelegate argkey_edit_blocks(text), to: Trailblazer.Loop.Tools.Native

  @doc false
  defdelegate raw_lines(body), to: Trailblazer.Loop.Tools.Tags
end
