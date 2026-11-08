defmodule Trailblazer.Loop.Streams do
  @moduledoc "Live logs of a model call: streamed tokens and the prompt-reading progress."

  require Logger
  alias Trailblazer.{Anomaly}
  alias Trailblazer.Loop.{CaseRecord}
  import Trailblazer.Loop.Ledger, only: [now: 0]

  # Every token the model streams goes to <case dir>/stream.log as it arrives,
  # and a line to the log at every 2 KB of reasoning or content, so a call that
  # thinks for minutes can be watched (`tail -f`) rather than waited out. Both
  # follow the stream's own events, never a clock. It runs in the model
  # client's process, which keeps the counters under this call's own ref; a log
  # that cannot be written never stops the task.
  @milestone 2048

  # The prompt is read before any token comes: the server's progress is logged
  # as it reports it (`processed` counts the cached tokens too). A call that
  # should have found its prefix cached and found none is an anomaly: the
  # cache was lost, most likely because another model took the router (Codex,
  # reviewing E25), and how often that happens is what decides whether the
  # cache must survive a model switch.
  @doc false
  def progress_log(st, role, expect_cache?) do
    key = {:trailblazer_progress, make_ref()}

    fn %{total: total, processed: processed, cache: cache} = p ->
      first? = Process.put(key, true) == nil

      if first? and expect_cache? and cache == 0 do
        Anomaly.report(:prompt_cache_miss, "case #{st.id}", %{role: role, prompt_tokens: total})
      end

      Logger.info(
        "trailblazer: case #{st.id} #{role} reading prompt #{processed}/#{total} tokens " <>
          "(#{cache} cached, #{div(p[:ms] || 0, 1000)} s)"
      )
    end
  end

  @doc false
  def stream_log(st, role) do
    path = Path.join(CaseRecord.dir(st.id), "stream.log")
    _ = File.mkdir_p(Path.dirname(path))
    _ = File.write(path, "\n===== #{role} call, #{DateTime.utc_now()} =====\n", [:append])
    {started, call} = {now(), {:trailblazer_stream, make_ref()}}

    fn %{reasoning: reasoning, content: content} ->
      {r, c, answering} = Process.get(call, {0, 0, false})
      header = if content != "" and not answering, do: "\n----- answer -----\n", else: ""
      _ = File.write(path, [reasoning, header, content], [:append])
      {r2, c2} = {r + byte_size(reasoning), c + byte_size(content)}

      if div(r2 + c2, @milestone) > div(r + c, @milestone) do
        Logger.info(
          "trailblazer: case #{st.id} #{role} streaming #{div(now() - started, 1000)} s, " <>
            "reasoning #{r2} B, content #{c2} B"
        )
      end

      Process.put(call, {r2, c2, answering or content != ""})
    end
  end
end
