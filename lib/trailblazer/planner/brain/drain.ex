defmodule Trailblazer.Planner.Brain.Drain do
  @moduledoc "The brain's drain: a release the router could not confirm, settled from the router's SSE unload stream."

  require Logger
  alias Trailblazer.{Backstop, Config}
  alias Trailblazer.Planner.Brain.Planning
  alias Trailblazer.Planner.Journal

  # The child that dies when its port closes; a port's stdin EOF kills the
  # guarded child even when the child never reads stdin (curl does not).
  @guard ~S|exec 3<&0; "$0" "$@" & child=$!; (read -r ignored <&3; kill -KILL "$child" 2>/dev/null) & guard=$!; wait "$child"; result=$?; kill "$guard" 2>/dev/null; wait "$guard" 2>/dev/null; exit "$result"|

  # The decision stays in the journal (the lease is unresolved) until the
  # cleanup is verified. The SSE stream is established first; once its HTTP
  # headers are in, a recheck releases once more — the unload may have
  # finished while the stream was connecting, and its single event must not
  # be missed. Nothing here repeats the model.
  @doc false
  def arm_drain(fp, lease, outcome, ref, reason, state) do
    case start_sse(state) do
      {:ok, port} ->
        backstop =
          Backstop.arm(:planner_drain, fp, {:ms, state.drain_limit_ms}, fn -> %{fp: fp} end)

        %{
          state
          | state: :draining,
            drain: %{
              port: port,
              backstop: backstop,
              fp: fp,
              lease: lease,
              outcome: outcome,
              ref: ref,
              reason: reason,
              phase: :connecting,
              settling: nil,
              unloaded: false,
              deadline: false,
              partial: ""
            }
        }

      {:error, why} ->
        Logger.warning("trailblazer: no SSE listener for the unload: #{inspect(why)}")
        fence(%{state | last_error: "no SSE listener: #{inspect(why)}"})
    end
  end

  defp start_sse(state) do
    cond do
      fun = state.start_sse -> fun.(sse_url())
      executable = System.find_executable("curl") -> sse_port(executable)
      true -> {:error, :curl_missing}
    end
  end

  defp sse_url do
    url = String.trim_trailing(Config.get(:planner_model_url) || "", "/")
    String.replace_suffix(url, "/v1", "") <> "/models/sse"
  end

  defp sse_port(executable) do
    port =
      Port.open(
        {:spawn_executable, ~c"/bin/sh"},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:line, 16_384},
          env: [{~c"LC_ALL", ~c"C"}],
          # -i prints the HTTP headers: their end marks a live stream
          args: ["-c", @guard, executable, "-N", "-s", "-i", sse_url()]
        ]
      )

    {:ok, port}
  end

  @doc false
  def sse_line(line, drain, state) do
    cond do
      drain.phase == :settling ->
        # a settle owns the outcome; further input changes nothing
        %{state | drain: %{drain | unloaded: drain.unloaded or frame(line) == :unload}}

      header?(line, ~r/^HTTP\/\S+ [45]\d\d/) ->
        Logger.warning(
          "trailblazer: the router's SSE stream refused: #{String.slice(line, 0, 60)}"
        )

        fence(state)

      line == "" and drain.phase == :connecting ->
        # headers are in: the stream is live, recheck the cleanup once now
        settle(drain, %{state | drain: %{drain | phase: :ready}})

      frame(line) == :unload ->
        settle(drain, state)

      true ->
        %{state | drain: drain}
    end
  end

  defp header?(line, regex), do: drain_phase_line(line, regex)
  defp drain_phase_line(line, regex), do: Regex.match?(regex, line)

  defp frame(line) do
    case String.trim_leading(line) do
      "data:" <> payload -> decode_frame(String.trim_leading(payload))
      _ -> nil
    end
  end

  defp decode_frame(payload) do
    planner_model = Config.get(:planner_model)

    with {:ok, json} <- Jason.decode(payload),
         "status_change" <- json["event"],
         %{"status" => "unloaded"} <- json["data"],
         model when is_binary(model) <- json["model"],
         true <- model in [planner_model, String.replace(planner_model, ":", "-")] do
      :unload
    else
      _ -> nil
    end
  end

  # One release attempt at a time owns the drain's outcome; the token makes a
  # late result from a superseded attempt harmless.
  @doc false
  def settle(drain, state) do
    token = make_ref()
    drain = %{drain | phase: :settling, settling: token}

    %Task{ref: task_ref} =
      Task.Supervisor.async_nolink(state.tasks, fn ->
        result =
          try do
            state.release_fun.(drain.lease)
          rescue
            error -> {:error, Exception.message(error)}
          end

        send(state.pid, {:drain_settled, token, result})
        :ok
      end)

    %{state | drain: drain, running: Map.put(state.running, task_ref, true), busy: state.busy + 1}
  end

  # The verified cleanup settles the lease; the retained outcome concludes.
  @doc false
  def conclude(drain, state) do
    state = %{state | state: :idle, drain: nil}

    if drain.outcome == :decided do
      Planning.resume(%{fp: drain.fp, ref: drain.ref, reason: drain.reason}, state)
    else
      Journal.record(drain.fp, "", "#{drain.outcome}", drain.ref, drain.reason)
      state
    end
  end

  @doc false
  def fence(state) do
    if state.drain do
      Backstop.disarm(state.drain.backstop)
      if Port.info(state.drain.port), do: Port.close(state.drain.port)
    end

    %{state | state: :fenced, drain: nil}
  end
end
