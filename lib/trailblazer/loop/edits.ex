defmodule Trailblazer.Loop.Edits do
  @moduledoc """
  SEARCH/REPLACE edit blocks: how the code model says what to change, how the
  change is matched against the file, and what the model is told on a miss.

  Derived from Aider (`aider/coders/editblock_coder.py`, v0.86.2, Apache-2.0,
  Paul Gauthier and contributors; see NOTICE). Changed from Aider:

  - written in Elixir; Python's `SequenceMatcher` ratio is replaced by the
    same measure over a character diff (`String.myers_difference/2`), so a
    window that differs by one character in every line still scores high
    (Aider compares whole lines and would find nothing);
  - all or nothing: if any block misses, no file is written, and the attempt
    is retried with the feedback (Aider writes the blocks that matched);
  - a block never edits a file it does not name (Aider retries a miss against
    the other files in the chat);
  - every path is held to the worktree: absolute paths, `..` and symlinks
    out are refused (A9/A10/E3 in the register);
  - the fuzzy edit-distance matcher Aider ships disabled is left out, and so
    are shell blocks (the loop runs no commands from the model).
  """
  @type block ::
          %{path: String.t(), type: :search, search: String.t(), replace: String.t()}
          | %{
              path: String.t(),
              type: :range,
              digest: String.t(),
              start: integer(),
              end: integer(),
              replace: String.t()
            }
  @type failure :: %{block: block(), reason: atom(), closest: String.t()}

  @doc false
  def failure(block, reason, closest), do: %{block: block, reason: reason, closest: closest}

  @doc delegate_to: {Trailblazer.Loop.Edits.Parse, :parse, 1}
  defdelegate parse(text), to: Trailblazer.Loop.Edits.Parse

  @doc delegate_to: {Trailblazer.Loop.Edits.Apply, :apply, 3}
  defdelegate apply(worktree, blocks, opts \\ []), to: Trailblazer.Loop.Edits.Apply

  @doc delegate_to: {Trailblazer.Loop.Edits.Ranges, :relocation_notice, 1}
  defdelegate relocation_notice(notice), to: Trailblazer.Loop.Edits.Ranges

  @doc delegate_to: {Trailblazer.Loop.Edits.Feedback, :feedback, 1}
  defdelegate feedback(failures), to: Trailblazer.Loop.Edits.Feedback

  @doc false
  defdelegate find_similar_lines(search, content, threshold \\ 0.6),
    to: Trailblazer.Loop.Edits.Feedback
end
