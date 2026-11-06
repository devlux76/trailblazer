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

  alias Trailblazer.{Files, Query}

  @cap 12_000
  @max_items 40
  @read_lines 400
  @names ~w(where uses impact read search)

  @doc "The answer cap, in characters."
  def cap, do: @cap

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

  @edit_tools ~w(submit_edits edit)

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

  @doc "Blocks of one edit-tool call: `submit_edits` (a batch) or `edit` (one block)."
  def edit_call_blocks("submit_edits", arguments), do: edit_blocks(arguments)

  def edit_call_blocks("edit", arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, %{} = block} ->
        case edit_blocks(Jason.encode!(%{blocks: [block]})) do
          {:ok, blocks} ->
            {:ok, blocks}

          {:error, _} ->
            {:error,
             "edit needs exactly path, search and replace as strings (path non-empty; empty search only creates a file)"}
        end

      _ ->
        {:error, "edit arguments must be a JSON object {path, search, replace}"}
    end
  end

  def edit_call_blocks(_name, _arguments), do: {:error, "not an edit tool"}

  @doc """
  Validates model arguments before the existing all-or-nothing edit application.

  `opts[:mode] == :text` is the plain-text coder's dialect: a range block may
  leave out `sha256` (a small model copying 64 hex characters makes them up;
  the first/last quotes already catch a stale or miscounted range), and a
  `{path, search, replace}` block is accepted only with an empty search, to
  create a file. Its refusals name the exact problem.
  """
  def edit_blocks(arguments, opts \\ [])

  def edit_blocks(arguments, opts) when is_binary(arguments) do
    mode = Keyword.get(opts, :mode)

    with {:ok, %{"blocks" => [_ | _] = blocks} = args} when map_size(args) == 1 <-
           Jason.decode(arguments),
         {:ok, decoded} <- decode_blocks(blocks, mode) do
      {:ok, decoded}
    else
      {:error, message} when is_binary(message) and mode == :text ->
        {:error, message}

      _ when mode == :text ->
        {:error,
         "the edits must be one JSON array of blocks: range blocks " <>
           "{path, start, end, first, last, replace} and, to create a file, {path, search: \"\", replace}"}

      _ ->
        {:error,
         "submit_edits requires a nonempty blocks array; each block is either " <>
           "{path, search, replace} strings, or a range block {path, sha256, start, end, first, last, replace} " <>
           "with a lowercase 64-hex sha256, integer line numbers and the quoted text of lines start and end"}
    end
  end

  def edit_blocks(_, _opts), do: {:error, "submit_edits arguments must be JSON"}

  @hex64 ~r/\A[0-9a-f]{64}\z/

  defp decode_blocks(blocks, mode) do
    blocks
    |> Enum.reduce_while({:ok, []}, fn block, {:ok, acc} ->
      case decode_block(block, mode) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      other -> other
    end
  end

  defp decode_block(%{"path" => path, "search" => search, "replace" => replace} = block, mode)
       when map_size(block) == 3 do
    cond do
      not (is_binary(path) and path != "" and is_binary(search) and is_binary(replace)) ->
        {:error, "legacy block needs a non-empty path and string search/replace"}

      mode == :text and search != "" ->
        {:error,
         "#{path}: a {path, search, replace} block only creates a new file (empty search); " <>
           "change an existing file with a range block {path, start, end, first, last, replace}"}

      true ->
        {:ok, %{path: path, search: search, replace: replace}}
    end
  end

  # Text mode: the same range block without sha256 (see edit_blocks/2).
  defp decode_block(%{"start" => _, "first" => _, "last" => _} = block, :text)
       when map_size(block) == 6 and not is_map_key(block, "sha256") do
    decode_block(Map.put(block, "sha256", nil), :text)
  end

  defp decode_block(
         %{
           "path" => path,
           "sha256" => sha256,
           "start" => start,
           "end" => last,
           "first" => first_text,
           "last" => last_text,
           "replace" => replace
         } = block,
         mode
       )
       when map_size(block) == 7 do
    cond do
      not (is_binary(path) and path != "") ->
        {:error, "range block needs a non-empty path"}

      not ((mode == :text and is_nil(sha256)) or
               (is_binary(sha256) and Regex.match?(@hex64, sha256))) ->
        {:error, "range block sha256 must be a lowercase 64-hex string"}

      not (is_integer(start) and start >= 1) ->
        {:error, "range block start must be an integer >= 1"}

      not (is_integer(last) and last >= 0) ->
        {:error, "range block end must be an integer >= 0"}

      not is_binary(replace) ->
        {:error, "range block replace must be a string"}

      not (is_binary(first_text) and is_binary(last_text)) ->
        {:error, "range block first and last must quote the current text of lines start and end"}

      true ->
        {:ok,
         %{
           path: path,
           digest: sha256,
           start: start,
           end: last,
           first: first_text,
           last: last_text,
           replace: replace,
           type: :range
         }}
    end
  end

  defp decode_block(_block, :text),
    do:
      {:error,
       "each block must be exactly a range block {path, start, end, first, last, replace} " <>
         "(sha256 optional) or, to create a file, {path, search: \"\", replace}"}

  defp decode_block(_block, _mode),
    do:
      {:error,
       "each block must be exactly {path, search, replace} or {path, sha256, start, end, first, last, replace}"}

  # An <edit ...> or <create ...> opening tag at the start of a line (a tag
  # mentioned inside a sentence is not one).
  @tag_open ~r/^[ \t]*<(edit|create)\b([^>\n]*)>/m

  @doc """
  Strict whole-message JSON fallback; code bytes and edit validation stay unchanged.

  With `mode: :text` (the plain-text coder) a reply holding `<edit>`/`<create>`
  tags is read as tags (code raw, see below); otherwise its JSON is read in the
  text dialect of `edit_blocks/2`, and may follow a sentence or two in one
  ```json fence.
  """
  def text_edit_blocks(text, opts \\ []) when is_binary(text) do
    if Keyword.get(opts, :mode) == :text and Regex.match?(@tag_open, text) do
      case tag_blocks(text) do
        {:ok, _} = ok ->
          ok

        # a reply that only mentions a tag may still carry JSON
        {:error, message} ->
          case json_edit_blocks(text, opts) do
            {:ok, _} = ok -> ok
            _ -> {:error, message}
          end
      end
    else
      json_edit_blocks(text, opts)
    end
  end

  ## The tag dialect (text mode)
  #
  # Code goes raw between tags, so a small model never escapes quotes,
  # backslashes or newlines (JSON strings would make it):
  #
  #     <edit path="lib/a.ex" start="3" end="4">
  #     <first>exact text of line 3</first>
  #     <last>exact text of line 4</last>
  #     <replace>
  #     whole replacement lines
  #     </replace>
  #     </edit>
  #
  #     <create path="lib/new.ex">
  #     the whole new file
  #     </create>

  # Code may itself contain these tags (an HTML file, a prompt, this module),
  # so the structure is read by position and checked as a whole: an opening
  # tag starts a line; a block ends at one of its closing tags that end a
  # line, the first one after which the rest of the reply also reads cleanly
  # (more blocks or plain text, never a stray closing tag, which would mean
  # the block was cut inside its own code); first/last are one line each;
  # replace runs to the LAST </replace> in its block. The model's bytes are
  # kept as written (a CRLF file's replacement may carry its CRs).
  @tag_attr ~r/(\w+)\s*=\s*"([^"]*)"/
  @tag_stray ~r/<\/(?:edit|create|replace)>[ \t]*\r?$/m
  @tag_unclosed "no complete <edit> or <create> block: end each with </edit> or </create> at the end of a line"

  defp tag_blocks(text) do
    case scan_tags(text) do
      {:ok, []} -> {:error, @tag_unclosed}
      other -> other
    end
  end

  defp scan_tags(text) do
    case Regex.run(@tag_open, text, return: :index, capture: :all) do
      nil ->
        if Regex.match?(@tag_stray, text),
          do: {:error, "a closing tag has no opening <edit> or <create>"},
          else: {:ok, []}

      [{at, len}, {k_at, k_len}, {a_at, a_len}] ->
        kind = binary_part(text, k_at, k_len)
        attrs = attrs(binary_part(text, a_at, a_len))
        rest = binary_part(text, at + len, byte_size(text) - at - len)

        cond do
          Regex.match?(@tag_stray, binary_part(text, 0, at)) ->
            {:error, "a closing tag has no opening <edit> or <create>"}

          true ->
            case Regex.scan(~r/<\/#{kind}>[ \t]*\r?(?=\n|\z)/, rest, return: :index) do
              [] ->
                {:error,
                 "an <#{kind}> block is not closed: end it with </#{kind}> at the end of a line"}

              closings ->
                close_block(kind, attrs, rest, Enum.map(closings, &hd/1))
            end
        end
    end
  end

  defp close_block(kind, attrs, rest, [{c_at, c_len} | later]) do
    body = binary_part(rest, 0, c_at)
    tail = binary_part(rest, c_at + c_len, byte_size(rest) - c_at - c_len)

    result =
      with {:ok, block} <- tag_block(kind, attrs, body),
           {:ok, blocks} <- scan_tags(tail),
           do: {:ok, [block | blocks]}

    case result do
      {:ok, _} -> result
      _ when later != [] -> close_block(kind, attrs, rest, later)
      error -> error
    end
  end

  defp attrs(text),
    do: @tag_attr |> Regex.scan(text, capture: :all_but_first) |> Map.new(fn [k, v] -> {k, v} end)

  defp tag_block("create", %{"path" => path}, body) when path != "" do
    with :ok <- no_tag_lines(body, path),
         do: {:ok, %{path: path, search: "", replace: raw_lines(body)}}
  end

  defp tag_block("create", _attrs, _body), do: {:error, ~s(<create> needs path="...")}

  defp tag_block("edit", %{"path" => path} = attrs, body) when path != "" do
    with :ok <- not_bare_code(body, path, attrs),
         {:ok, start} <- tag_int(attrs, "start", 1),
         {:ok, last} <- tag_int(attrs, "end", 0),
         {:ok, first_text} <- tag_inner(body, "first", path),
         {:ok, last_text} <- tag_inner(body, "last", path),
         {:ok, replace} <- tag_inner(body, "replace", path),
         :ok <- no_tag_lines(replace, path) do
      {:ok,
       %{
         path: path,
         digest: nil,
         start: start,
         end: last,
         first: anchor(first_text),
         last: anchor(last_text),
         replace: raw_lines(replace),
         type: :range
       }}
    end
  end

  defp tag_block("edit", _attrs, _body),
    do: {:error, ~s(<edit> needs path="..." start="N" end="M")}

  # New text with lines that start like the dialect's own tags (a file that
  # documents this format) cannot be told apart from where a block ends:
  # two example blocks inside a replacement parse as a cut edit plus an
  # invented one (review of 89337f5). Refused, never guessed; tags inside a
  # line (strings, comments, regexes) are fine.
  defp no_tag_lines(text, path) do
    if Regex.match?(~r/^[ \t]*<\/?(?:edit|create|replace|first|last)\b/m, text),
      do:
        {:error,
         "#{path}: the new text has lines that start with edit tags (<edit>, </replace>, ...), " <>
           "so the host cannot tell where the block ends; keep those lines out of this edit's range"},
      else: :ok
  end

  # Seen live (Bolt, 2026-11-05): an <edit> holding only the new code, without
  # its quotes or <replace>. Said plainly; the loop adds the named lines.
  defp not_bare_code(body, path, attrs) do
    if Regex.match?(~r/<(?:first|last|replace)>/, body),
      do: :ok,
      else:
        {:error,
         "#{path} lines #{attrs["start"]}-#{attrs["end"]}: the <edit> holds only code; " <>
           "it needs <first> (exact text of line #{attrs["start"]}), <last> (exact text of line " <>
           "#{attrs["end"]}) and the new lines inside <replace>...</replace>"}
  end

  defp tag_int(attrs, key, min) do
    case Integer.parse(Map.get(attrs, key, "")) do
      {n, ""} when n >= min -> {:ok, n}
      _ -> {:error, ~s(<edit> needs #{key}="N", a whole number >= #{min})}
    end
  end

  # first/last: within one line, up to the line's last closing tag;
  # replace: across lines, up to the block's last </replace>.
  defp tag_inner(body, tag, path) do
    re =
      if tag == "replace",
        do: ~r/<replace>(.*)<\/replace>/s,
        else: ~r/<#{tag}>([^\n]*)<\/#{tag}>/

    case Regex.run(re, body, capture: :all_but_first) do
      [inner] ->
        {:ok, inner}

      # Seen live (Bolt, 2026-11-05): <replace> opened, the block closed by
      # </edit> with no </replace>. The block's end is already settled, so
      # the replacement is the rest of the block.
      nil when tag == "replace" ->
        case Regex.run(~r/<replace>(.*)\z/s, body, capture: :all_but_first) do
          [inner] -> {:ok, inner}
          nil -> {:error, "#{path}: <edit> needs <replace>...</replace>"}
        end

      nil ->
        {:error, "#{path}: <edit> needs <#{tag}>...</#{tag}>"}
    end
  end

  # One quoted line; a copied "12| " number prefix from the numbered source is
  # not part of it.
  defp anchor(text),
    do: text |> String.replace(~r/\A[\r\n]+|[\r\n]+\z/, "") |> String.replace(~r/\A\d+\| ?/, "")

  @doc false
  # Whole lines: the newline after the opening tag and the indentation before
  # the closing tag are layout; a non-empty body ends with a newline.
  def raw_lines(body) do
    body =
      body
      |> String.replace(~r/\A\r?\n/, "")
      |> String.replace(~r/(\r?\n)[ \t]*\z/, "\\1")

    cond do
      Regex.match?(~r/\A[ \t]*\z/, body) -> ""
      String.ends_with?(body, "\n") -> body
      true -> body <> "\n"
    end
  end

  defp json_edit_blocks(text, opts) do
    text = String.trim(text)
    text_mode? = Keyword.get(opts, :mode) == :text
    structured? = String.starts_with?(text, ["[", "{", "```json", "```JSON"])

    payload =
      case Regex.run(~r/\A```json[ \t]*\R([\s\S]*)\R```\z/i, text) do
        [_, json] -> json
        _ -> text
      end

    {structured?, payload} =
      case {structured?,
            text_mode? && Regex.run(~r/^```json[ \t]*\R([\s\S]*?)\R```[ \t]*$/im, text)} do
        {false, [_, json]} -> {true, json}
        _ -> {structured?, payload}
      end

    if structured? do
      case Jason.decode(payload) do
        {:ok, blocks} when is_list(blocks) -> edit_blocks(Jason.encode!(%{blocks: blocks}), opts)
        {:ok, args} when is_map(args) -> edit_blocks(Jason.encode!(args), opts)
        _ -> {:error, "structured edits must be one complete JSON array or blocks object"}
      end
    else
      :none
    end
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
         {:ok, args} <- decode(arguments) do
      name |> answer(target, args, opts) |> capped()
    else
      {:error, message} -> "error: " <> message
    end
  rescue
    e -> "error: #{name} failed: #{Exception.message(e)}"
  catch
    kind, reason -> "error: #{name} failed: #{inspect({kind, reason})}"
  end

  defp known(name) when name in @names, do: :ok

  defp known(name),
    do:
      {:error,
       "no tool named #{inspect(to_string(name))}; the tools are #{Enum.join(@names, ", ")}"}

  defp decode(%{} = args), do: {:ok, args}

  defp decode(text) when is_binary(text) do
    case Jason.decode(if(String.trim(text) == "", do: "{}", else: text)) do
      {:ok, %{} = args} -> {:ok, args}
      {:ok, _other} -> {:error, "arguments must be a JSON object"}
      {:error, e} -> {:error, "arguments are not valid JSON (#{Exception.message(e)})"}
    end
  end

  defp decode(_other), do: {:error, "arguments must be a JSON object"}

  ## The questions

  defp answer("where", t, args, opts) do
    with {:ok, name} <- required_string(args, "where", "name") do
      t.repo
      |> Query.where_declared(name, opts)
      |> lines("no definition named #{inspect(name)}", &definition/1)
    end
  end

  defp answer("uses", t, args, opts) do
    with {:ok, name} <- required_string(args, "uses", "name") do
      t.repo
      |> Query.who_uses(name, opts)
      |> lines("nothing uses #{inspect(name)}", fn u ->
        "#{u.node.path}:#{u.line || u.node.start_line}  #{u.node.qualified}  #{u.kind} #{u.target.qualified}" <>
          uncertain(u.uncertain)
      end)
    end
  end

  defp answer("impact", t, args, opts) do
    with {:ok, name} <- required_string(args, "impact", "name"),
         {:ok, depth} <- optional_integer(args, "impact", "depth", 2, 1..5) do
      t.repo
      |> Query.impact_of(name, depth, opts)
      |> lines("nothing depends on #{inspect(name)}", fn i ->
        "#{i.distance} #{i.via}  #{definition(i.node)}" <> uncertain(i.uncertain)
      end)
    end
  end

  defp answer("read", t, args, opts) do
    with {:ok, path} <- required_string(args, "read", "path"),
         {:ok, first} <- optional_integer(args, "read", "start", 1, 1..1_000_000_000),
         {:ok, last} <-
           optional_integer(args, "read", "end", first + @read_lines - 1, first..1_000_000_000) do
      last = min(last, first + @read_lines - 1)

      case Files.read(t.worktree || t.repo, path) do
        {:ok, text} ->
          all = text |> String.split(~r/\r?\n/) |> drop_last_empty()
          total = length(all)
          header = "path: #{path}\nsha256: #{sha256(text)}\nlines: #{total}\n"

          body =
            case all |> Enum.with_index(1) |> Enum.slice((first - 1)..(last - 1)//1) do
              [] ->
                "#{path} has #{total} lines, no line #{first}"

              numbered ->
                shown = Enum.map_join(numbered, "\n", fn {line, n} -> "#{n}| #{line}" end)
                {_, shown_last} = List.last(numbered)
                wanted = Map.get(args, "end", total)

                # say where the read stopped, so the model reads on rather than
                # taking a cut file for a short one
                if shown_last < min(wanted, total),
                  do:
                    shown <>
                      "\n... cut at line #{shown_last} of #{total}: read again from #{shown_last + 1}",
                  else: shown
            end

          header <> body

        {:error, :outside_repo} ->
          # a model that invents a root (/testbed/..., /workspace/...) keeps
          # asking for it: the tail that is a real file is read instead
          case relative_tail(t.worktree || t.repo, path) do
            nil ->
              {:error, "#{path} is outside the repository; paths are repository-relative"}

            found ->
              case answer("read", t, Map.put(args, "path", found), opts) do
                text when is_binary(text) ->
                  "note: #{path} is outside the repository; read #{found} (paths are repository-relative)\n" <>
                    text

                other ->
                  other
              end
          end

        {:error, _} ->
          {:error, "no file #{path}"}
      end
    end
  end

  defp answer("search", t, args, opts) do
    with {:ok, query} <- required_string(args, "search", "query"),
         {:ok, limit} <- optional_integer(args, "search", "limit", 8, 1..20) do
      t.repo
      |> Query.search(query, limit, opts)
      |> lines("nothing matches #{inspect(query)}", fn h ->
        "#{:erlang.float_to_binary(h.score / 1, decimals: 2)} #{h.via}  #{definition(h.node)}"
      end)
    end
  end

  # Small models invent absolute roots (e.g. /home/x/workspace/src/a.ts): the
  # longest tail of the path that is a real repository file, or nil.
  defp relative_tail(root, path) do
    parts = path |> Path.split() |> Enum.reject(&(&1 in ["/", ".", ".."]))

    0..max(length(parts) - 1, 0)//1
    |> Enum.map(&(parts |> Enum.drop(&1) |> Path.join()))
    |> Enum.find(&(&1 != "" and match?({:ok, _}, Files.read(root, &1))))
  end

  defp definition(n) do
    sig = if n.signature in [nil, ""], do: "", else: "  " <> first_line(n.signature)
    stale = if n.stale, do: "  (stale)", else: ""
    "#{n.qualified}  #{n.kind}  #{n.path}:#{n.start_line}-#{n.end_line}#{sig}#{stale}"
  end

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 160)

  defp uncertain(true), do: "  (uncertain)"
  defp uncertain(_), do: ""

  defp lines({:error, :not_watched}, _empty, _fun), do: {:error, "the repository is not watched"}
  defp lines({:error, reason}, _empty, _fun), do: {:error, inspect(reason)}
  defp lines([], empty, _fun), do: empty

  defp lines(items, _empty, fun) do
    shown = items |> Enum.take(@max_items) |> Enum.map_join("\n", fun)
    more = length(items) - @max_items
    if more > 0, do: shown <> "\n... #{more} more not shown", else: shown
  end

  defp drop_last_empty(lines),
    do: if(List.last(lines) == "", do: Enum.drop(lines, -1), else: lines)

  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  ## Arguments

  defp required_string(args, tool, key) do
    case args[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{tool} needs \"#{key}\" (a non-empty string)"}
    end
  end

  defp optional_integer(args, tool, key, default, range) do
    case Map.get(args, key) do
      nil ->
        {:ok, default}

      value when is_integer(value) ->
        if value in range, do: {:ok, value}, else: bad_int(tool, key, range)

      _ ->
        bad_int(tool, key, range)
    end
  end

  defp bad_int(tool, key, first..last//_),
    do: {:error, "#{tool}: \"#{key}\" must be an integer from #{first} to #{last}"}

  ## Output

  defp capped({:error, message}), do: "error: " <> message

  defp capped(text) when byte_size(text) <= @cap, do: text

  defp capped(text) do
    if String.length(text) <= @cap do
      text
    else
      kept = String.slice(text, 0, @cap)
      cut = text |> String.slice(@cap..-1//1) |> String.split("\n") |> length()
      kept <> "\n... cut here: #{cut} more lines (ask for a narrower range)"
    end
  end
end
