defmodule Trailblazer.Loop.Tools.Tags do
  @moduledoc "The tag dialect (text mode): <edit> and <create> blocks read by position, code raw between tags."

  alias Trailblazer.Loop.Tools.Native

  @tag_open ~r/^[ \t]*<(edit|create)\b([^>\n]*)>/m
  @tag_attr ~r/(\w+)\s*=\s*"([^"]*)"/
  @tag_stray ~r/<\/(?:edit|create|replace)>[ \t]*\r?$/m
  @tag_unclosed "no complete <edit> or <create> block: end each with </edit> or </create> at the end of a line"

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

  @doc false
  def tag_blocks(text) do
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

  @doc false
  def attrs(text),
    do: @tag_attr |> Regex.scan(text, capture: :all_but_first) |> Map.new(fn [k, v] -> {k, v} end)

  defp tag_block("create", %{"path" => path}, body) when path != "" do
    with :ok <- no_tag_lines(body, path),
         do: {:ok, %{path: path, search: "", replace: raw_lines(body)}}
  end

  defp tag_block("create", _attrs, _body), do: {:error, ~s(<create> needs path="...")}

  defp tag_block("edit", %{"path" => path} = attrs, body) when path != "" do
    with :ok <-
           Trailblazer.Loop.EditForm.check(body, path, attrs) || not_bare_code(body, path, attrs),
         {:ok, start} <- tag_int(attrs, "start", 1),
         {:ok, last} <- tag_int(attrs, "end", 0),
         first_text = optional_inner(body, "first"),
         last_text = optional_inner(body, "last"),
         {:ok, replace} <- tag_inner(body, "replace", path),
         :ok <- no_tag_lines(replace, path) do
      {:ok,
       %{
         path: path,
         digest: nil,
         start: start,
         end: last,
         first: first_text && Native.anchor(first_text),
         last: last_text && Native.anchor(last_text),
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

  @doc false
  def tag_int(attrs, key, min) do
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

  # <first>/<last> are optional and may quote several lines (seen live,
  # LFM2.5-24B 2026-11-06: lines 7-8 inside <first>, no <last>); a missing one
  # is filled from the file at its stated line by Edits. Up to the first
  # closing tag, so a quote never runs into the next one.
  defp optional_inner(body, tag) do
    case Regex.run(~r/<#{tag}>(.*?)<\/#{tag}>/s, body, capture: :all_but_first) do
      [inner] -> inner
      nil -> nil
    end
  end

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
end
