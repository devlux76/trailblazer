defmodule Trailblazer.Loop do
  @moduledoc """
  One coding task, start to finish (design §5): open the case and a worktree
  of its own, build the trail, then up to three attempts, each one a prompt
  (with the core's questions as tools), the edits, the project's check and a
  review in a fresh context. A task whose check and review pass is committed
  on `trailblazer/<case>`; one with no check is `unverified` and left
  uncommitted; one that fails three times comes back `failed` with its
  dossier (§7.5; calling a friend is phase 3). Trailblazer never merges,
  never pushes and never touches the caller's checkout.

  Every stage is recorded with `CaseRecord` before the next begins, and a
  crash ends the public task as `failed`; durable Git intents are reconciled
  before recovery closes its record (E16).
  While the model generates, the embedding gate is held, so embedding and
  the model do not share the CPU (design §7.2).

  A task runs in the calling process; its running totals (model calls and
  tokens, the files changed, the last check) are kept in that process's
  dictionary for the task's duration.

  Collaborators are options, so the loop can be tested without a model:
  `:model` (`Trailblazer.Model`), `:workspace`, `:check`, `:tools`, `:trail`
  (a function of repo, request and options), `:gate` (`{hold, release}`
  functions, or `false`), `:model_opts`, `:check_opts` and `:query_opts`.
  """

  require Logger
  alias Trailblazer.{Config, Files, Trail}

  alias Trailblazer.Loop.{
    Attempts,
    CaseRecord,
    Check,
    Context,
    Lifecycle,
    Outcome,
    Request,
    Workspace
  }

  import Trailblazer.Loop.Ledger,
    only: [tally: 1, tally: 2, mod: 3, query_opts: 1, now: 0, record: 3, brief: 2, describe: 1]

  @tally {__MODULE__, :tally}

  @doc """
  Runs `task` (design §7.1: `repo`, `request`, and optionally `files`,
  `design`, `check`, `from`, `read_rounds` from 0 to 6) and gives the report (§7.6). `opts[:case_id]`
  is a case already opened for the task (the API opens it before queueing).
  """
  @spec run(map(), keyword()) :: map()
  def run(task, opts \\ []) do
    task = Request.normalize(task)

    Process.put(@tally, %{
      model_calls: 0,
      prompt_tokens: 0,
      completion_tokens: 0,
      coder_calls: 0,
      changed: [],
      check: nil,
      ws: nil,
      workspace_closed: false,
      verification_ms: 0,
      compiled: nil,
      test_bugs: %{}
    })

    id =
      case opts[:case_id] do
        nil -> elem(CaseRecord.open(task), 1)
        id -> id
      end

    st = %{id: id, task: task, opts: opts, started: now(), ws: nil, failures: []}

    report =
      try do
        work(st)
      rescue
        e -> Outcome.crashed(%{st | ws: tally(:ws)}, Exception.format(:error, e, __STACKTRACE__))
      catch
        :throw, {:lifecycle_error, reason} ->
          Outcome.report(%{st | ws: tally(:ws)}, :failed, "Lifecycle failed: #{inspect(reason)}.")

        kind, reason ->
          Outcome.crashed(%{st | ws: tally(:ws)}, Exception.format(kind, reason, __STACKTRACE__))
      end

    _ = Lifecycle.reported(id, report)
    report = Outcome.coordinate(id, report, opts)

    case CaseRecord.close(id, report) do
      :ok ->
        Logger.info("trailblazer: case #{id} report #{brief(:report, report)}")

        # Outcome memory: recorded in the background, never affects the case.
        # (read directly: Config.get treats a configured false as unset)
        if Application.get_env(:trailblazer, :memory_record, true) do
          Trailblazer.Memory.record_async(id, %{
            model: Config.get(:code_model),
            reviewer: Config.get(:review_model)
          })
        end

      error ->
        Logger.error("trailblazer: case #{id} could not be closed: #{inspect(error)}")
    end

    Process.delete(@tally)
    report
  end

  # The trail is built from the repository, not the worktree, so it is built
  # while the worktree is made and provisioned (design §13.4).
  defp work(st) do
    trail_job = job(fn -> trail(st) end)

    case open_workspace(st) do
      {:ok, st} ->
        examples_job =
          if st.task.examples and is_nil(st.task.replay_reply_from),
            do: job(fn -> examples(st) end)

        trail = await_job(trail_job, st)
        files = files(st)
        check = st.task.check || mod(st, :check, Check).default(st.ws.path)
        pattern = Context.pattern(st)

        st =
          Map.put(st, :head, %{
            check: check,
            pattern: pattern,
            evidence: Trailblazer.Loop.DependencyEvidence.gather(st.task),
            examples:
              examples_job && recorded_examples(st, await_job(examples_job, st, :examples, nil))
          })

        record(st, :attempt, %{
          stage: :plan,
          check: check,
          files: Enum.map(files, &elem(&1, 0)),
          pattern: pattern && elem(pattern, 0)
        })

        Attempts.attempts(st, trail, files, check, 1, nil)

      {:error, reason} ->
        stop_job(trail_job)
        record(st, :error, %{stage: :workspace, reason: reason})
        Outcome.report(st, :failed, "No worktree could be made: #{describe(reason)}.")

      {:error, st, reason} ->
        stop_job(trail_job)
        record(st, :error, %{stage: :provision, reason: reason})

        Outcome.report(
          st,
          :failed,
          "The worktree's dependencies could not be set up: #{describe(reason)}."
        )
    end
  end

  # A piece of work in a monitored process of its own; its answer comes back
  # as a message, and its death is an answer too (design §13.2, J7).
  defp job(fun) do
    parent = self()
    token = make_ref()
    {pid, mon} = spawn_monitor(fn -> send(parent, {token, fun.()}) end)
    {token, pid, mon}
  end

  defp await_job({token, _pid, mon}, st, stage \\ :trail, dead \\ "") do
    receive do
      {^token, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, _pid, reason} ->
        record(st, :attempt, %{stage: stage, error: Exception.format_exit(reason)})
        dead
    end
  end

  # Similar past changes (Loop.Examples), recalled in a job beside the trail;
  # eligible: the case repository's commits reachable from the base, other
  # repositories' commits from before the base's time. Without both, none.
  defp examples(st) do
    git = fn args -> System.cmd("git", args, cd: st.ws.path, stderr_to_stdout: true) end

    # "own" is by commit, not by clone name: a replay from a scratch clone
    # still knows its repository's commits
    with {time, 0} <- git.(["show", "-s", "--format=%ct", st.ws.base]),
         {shas, 0} <- git.(["rev-list", st.ws.base]),
         {all, 0} <- git.(["rev-list", "--all"]) do
      mod(st, :examples, Trailblazer.Loop.Examples).recall(st.task,
        before: time |> String.trim() |> String.to_integer(),
        reachable: MapSet.new(String.split(shas)),
        known: MapSet.new(String.split(all))
      )
    else
      _ -> {:error, :base_history}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Each prompt records which entries it showed, so outcomes trace back to them.
  defp recorded_examples(st, {:ok, r}) do
    record(st, :attempt, %{
      stage: :examples,
      how: r.how,
      considered: r.considered,
      ids: r.ids,
      rerank_error: r.rerank_error && inspect(r.rerank_error)
    })

    r.text
  end

  defp recorded_examples(st, {:error, reason}) do
    record(st, :attempt, %{stage: :examples, error: inspect(reason)})
    nil
  end

  defp recorded_examples(_st, nil), do: nil

  defp recorded_examples(st, other) do
    record(st, :attempt, %{stage: :examples, error: "unexpected: " <> inspect(other)})
    nil
  end

  defp stop_job({token, pid, mon}) do
    Process.demonitor(mon, [:flush])
    Process.exit(pid, :kill)

    receive do
      {^token, _} -> :ok
    after
      0 -> :ok
    end
  end

  defp open_workspace(st) do
    workspace = mod(st, :workspace, Workspace)

    with {:ok, ws} <- workspace.open(st.task.repo, st.id) do
      st = %{st | ws: ws}
      tally(:ws, ws)

      with {:ok, _} <- Lifecycle.admit(st.id, st.task, ws) do
        record(st, :attempt, %{stage: :workspace, path: ws.path, branch: ws.branch, base: ws.base})

        # the repository's ignored dependency directories, linked or copied in,
        # so the check can run in the worktree
        case workspace.provision(ws, st.task.repo) do
          :ok -> {:ok, st}
          {:error, reason} -> {:error, st, reason}
        end
      else
        {:error, reason} -> {:error, st, {:lifecycle, reason}}
      end
    end
  end

  defp trail(st) do
    build = Keyword.get(st.opts, :trail, &Trail.build/3)
    files = st.task.files

    # the named files seed the trail, and their chunks reach the model through
    # it like any other: a file is never sent whole, the model reads the rest
    opts =
      query_opts(st)
      |> Keyword.merge(
        files: files,
        rerank: Application.get_env(:trailblazer, :loop_rerank, true)
      )
      |> Keyword.put_new(:budget, Config.get(:trail_tokens))

    case build.(st.task.repo, st.task.request, opts) do
      %{text: text} = trail ->
        record(st, :attempt, %{stage: :trail, text: text, notes: Map.get(trail, :notes, [])})
        text

      {:error, reason} ->
        record(st, :attempt, %{stage: :trail, error: reason})
        ""
    end
  end

  # The files the caller named, by name and size only: their chunks are in the
  # trail, and `read` (or `search`) gives the model whatever else it needs.
  defp files(st) do
    Enum.map(st.task.files, fn path ->
      case Files.read(st.ws.path, path) do
        {:ok, text} -> {path, Context.lines(text)}
        {:error, _} -> {path, :missing}
      end
    end)
  end

  @doc false
  defdelegate looping_blocks?(content), to: Trailblazer.Loop.EditBlocks
end
