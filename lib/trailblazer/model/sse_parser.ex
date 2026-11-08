# Copied from mirai-agent; kept local per docs/design-2.md §9.
defmodule Trailblazer.Model.SSEParser do
  @moduledoc """
  Pure incremental SSE framing parser (docs/13-llm-runtime.md §13.3(2)).

  Takes raw bytes via `feed/2`, returns `{frames, new_state}` where
  a frame is one of:
    - `{:data, binary}` — accumulated data lines
    - `:done` — the `data: [DONE]` sentinel
    - `{:error, :protocol, detail}` — garbled input, resynced

  Handles: split-at-any-byte boundaries, multi-line `data:`,
  comment lines (`:`), unknown field names (ignored), LF and CRLF.
  Never raises — returns the error frame and resyncs.
  """

  defstruct input_buffer: "", pending_frames: []

  @type frame :: {:data, binary()} | :done | {:error, :protocol, String.t()}
  @type t :: %__MODULE__{input_buffer: binary(), pending_frames: [frame()]}

  @doc "Return a fresh parser state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feed raw bytes into the parser. Returns `{frames, new_state}`.

  Complete frames are emitted immediately; only the next partial event is
  buffered. Holding complete frames behind a partial suffix would hide tokens
  from the first-token deadline and lose them on a cut stream.
  """
  @spec feed(t(), binary()) :: {[frame()], t()}
  def feed(%__MODULE__{} = parser, bytes) when is_binary(bytes) do
    buf = parser.input_buffer <> bytes
    {new_frames, remaining} = extract_complete(buf, [])
    {parser.pending_frames ++ new_frames, %{parser | input_buffer: remaining, pending_frames: []}}
  end

  # ── internal ──────────────────────────────────────────────────

  # Extract all complete events from buf, return {frames, leftover}.
  defp extract_complete(buf, acc) do
    case split_event(buf) do
      {:complete, event_lines, rest} ->
        frames = classify_event(event_lines)
        extract_complete(rest, acc ++ frames)

      :incomplete ->
        {acc, buf}
    end
  end

  # Split on double-newline (blank line) to extract one SSE event.
  defp split_event(buf) do
    case find_event_end(buf, 0) do
      {:ok, pos} ->
        event_end =
          if pos > 0 and binary_part(buf, pos - 1, 1) == "\r",
            do: pos - 1,
            else: pos

        event_bin = binary_part(buf, 0, event_end)

        skip =
          case binary_part(buf, pos, byte_size(buf) - pos) do
            <<"\r\n\r\n", _::binary>> -> pos + 4
            <<"\r\n\n", _::binary>> -> pos + 3
            <<"\n\r\n", _::binary>> -> pos + 3
            <<"\n\n", _::binary>> -> pos + 2
            _ -> pos + 2
          end

        rest = binary_part(buf, skip, byte_size(buf) - skip)
        lines = String.split(event_bin, ~r/\r?\n/)
        {:complete, lines, rest}

      :not_found ->
        :incomplete
    end
  end

  defp find_event_end(buf, pos) do
    case buf do
      <<_::binary-size(^pos), "\n\n", _::binary>> -> {:ok, pos}
      <<_::binary-size(^pos), "\r\n\r\n", _::binary>> -> {:ok, pos}
      _ when pos >= byte_size(buf) - 1 -> :not_found
      _ -> find_event_end(buf, pos + 1)
    end
  end

  # Classify lines of one SSE event into a list of frames.
  defp classify_event(lines), do: classify_lines(lines, [])

  defp classify_lines([], data_acc) do
    if data_acc == [], do: [], else: [build_data_frame(data_acc)]
  end

  defp classify_lines([line | rest], data_acc) do
    cond do
      line == "" ->
        classify_lines(rest, data_acc)

      garbage?(line) ->
        data_frame = if data_acc == [], do: [], else: [build_data_frame(data_acc)]
        data_frame ++ [{:error, :protocol, line} | classify_lines(rest, [])]

      true ->
        case classify_line(line) do
          {:data, value} -> classify_lines(rest, [value | data_acc])
          :skip -> classify_lines(rest, data_acc)
        end
    end
  end

  defp classify_line(":" <> _), do: :skip
  defp classify_line("data:" <> value), do: {:data, String.trim_leading(value, " ")}
  defp classify_line(_), do: :skip

  defp garbage?(line), do: not String.valid?(line)

  defp build_data_frame(["[DONE]" | _]), do: :done

  defp build_data_frame(data_acc) do
    data = data_acc |> Enum.reverse() |> Enum.join("\n")
    {:data, data}
  end
end
