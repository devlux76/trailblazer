defmodule Trailblazer.Loop.Tools.Definitions do
  @moduledoc "Tool definitions the model is offered: the five questions and the edit submission tools."

  @read_lines 400
  @edit_tools ~w(submit_edits edit)

  @doc "OpenAI tool definitions for the five questions."
  @spec definitions() :: [map()]
  def definitions do
    [
      tool(
        "where",
        "Where a name is defined: each definition with its file and lines.",
        %{
          name: string("A bare, qualified or Module.fun/arity name, e.g. put or Mini.Store.put/2")
        },
        [:name]
      ),
      tool(
        "uses",
        "Who uses a definition: each caller or reference, with the line it is on.",
        %{name: string("The definition's name")},
        [:name]
      ),
      tool(
        "impact",
        "What a change to a definition affects: its users, their users, and so on.",
        %{
          name: string("The definition's name"),
          depth: %{
            type: "integer",
            minimum: 1,
            maximum: 5,
            description: "How far to walk (default 2)"
          }
        },
        [:name]
      ),
      tool(
        "read",
        "Lines of a file in the repository, numbered. The answer starts with a compact path/sha256/lines header: sha256 covers the file's full bytes exactly as read. At most #{@read_lines} lines per call.",
        %{
          path: string("Path relative to the repository root"),
          start: %{type: "integer", minimum: 1, description: "First line (default 1)"},
          end: %{
            type: "integer",
            minimum: 1,
            description: "Last line (default start + #{@read_lines - 1})"
          }
        },
        [:path]
      ),
      tool(
        "search",
        "Definitions matching words or a name: exact names, then meaning, then literal text.",
        %{
          query: string("What to look for"),
          limit: %{type: "integer", minimum: 1, maximum: 20, description: "How many (default 8)"}
        },
        [:query]
      )
    ]
  end

  @doc "Native submission of edits; applying them remains the loop's responsibility."
  def edit_definition(mode \\ :both) when mode in [:both, :ranges] do
    definition =
      tool(
        "submit_edits",
        "Submit all code changes for checking and review. Two block kinds are accepted. Range block: path (repository-relative), sha256 (lowercase hex), start and end (1-based line numbers, inclusive; set end to start-1 to insert before that line), first and last (the exact current text of lines start and end, empty when outside the file), replace. Use an empty search string for a new file. Do not call read/search in the same response.",
        %{
          blocks: %{
            type: "array",
            minItems: 1,
            items: %{
              anyOf: [
                %{
                  type: "object",
                  additionalProperties: false,
                  properties: %{
                    path: string("Repository-relative file path"),
                    search:
                      string(
                        "Exact existing text including whitespace; empty only for a new or empty file"
                      ),
                    replace: string("Replacement text, or entire contents of a new file")
                  },
                  required: ["path", "search", "replace"]
                },
                %{
                  type: "object",
                  additionalProperties: false,
                  properties: %{
                    path: string("Repository-relative file path"),
                    sha256: %{
                      type: "string",
                      pattern: "^[0-9a-f]{64}$",
                      description: "SHA-256 of the file's full bytes, exactly as read from disk"
                    },
                    start: %{
                      type: "integer",
                      minimum: 1,
                      description: "First line of the range, 1-based and inclusive"
                    },
                    end: %{
                      type: "integer",
                      minimum: 0,
                      description:
                        "Last line of the range, inclusive; end = start - 1 inserts before that line"
                    },
                    first:
                      string(
                        "Exact current text of line start, copied from the numbered source; empty when start is past the last line"
                      ),
                    last:
                      string(
                        "Exact current text of line end, copied from the numbered source; empty when end is 0"
                      ),
                    replace:
                      string(
                        "Replacement whole lines; empty deletes. A missing final LF/CRLF is retained before an untouched following line. EOF text stays exact"
                      )
                  },
                  required: ["path", "sha256", "start", "end", "first", "last", "replace"]
                }
              ]
            }
          }
        },
        [:blocks]
      )

    if mode == :ranges do
      items = definition.function.parameters.properties.blocks.items
      range = Enum.find(items.anyOf, &Map.has_key?(&1.properties, :sha256))
      definition = put_in(definition.function.parameters.properties.blocks.items, range)

      put_in(
        definition.function.description,
        "Submit the complete batch of read-backed range edits for the existing named files. Copy sha256 from read; start/end are original inclusive lines; end=start-1 inserts; first/last quote the current text of lines start/end, so a miscounted range is refused instead of applied. No SEARCH blocks in this format. Do not call read/search in the same response."
      )
    else
      definition
    end
  end

  @doc "Names of the tools whose calls are edit submissions."
  def edit_tools, do: @edit_tools

  @doc """
  The flat edit tool: one change per call with plain string arguments, so a
  model whose native tool format carries strings raw (e.g. Spark's
  `<arg_value>`) writes code unescaped. Several `edit` calls in one reply,
  with or without `submit_edits`, form one all-or-nothing batch.
  """
  def flat_edit_definition do
    tool(
      "edit",
      "Replace exact existing text in one file. Call it once per change; several edit calls in one reply (with or without submit_edits) form one all-or-nothing batch. Do not call read/search in the same response.",
      %{
        path: string("Repository-relative file path"),
        search:
          string(
            "Exact existing text to replace, copied with its indentation; it must match one place. Empty only to create a new or empty file"
          ),
        replace: string("The replacement text")
      },
      [:path, :search, :replace]
    )
  end

  defp tool(name, description, properties, required) do
    %{
      type: "function",
      function: %{
        name: name,
        description: description,
        parameters: %{
          type: "object",
          properties: properties,
          required: Enum.map(required, &to_string/1)
        }
      }
    }
  end

  defp string(description), do: %{type: "string", description: description}
end
