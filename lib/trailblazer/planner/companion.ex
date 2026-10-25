defmodule Trailblazer.Planner.Companion do
  @moduledoc """
  Supervised owner of planner assignments (trailblazer:9fa7ba4). The planner CLI
  only records a request; admission stores the card reference with the case in
  one transaction, before the accepted reply can leave. From then on this
  process owns the card:

    * when the case closes `fixed`, it verifies the candidate independently in a
      fresh detached worktree with the admitted check, then records planner
      `done` with the evidence, or `block` with the failure;
    * when the case closes any other way, it records `block` with the summary;
    * a deadline is a backstop, never a retry: if the case is still open when it
      passes, the card is blocked for investigation and the case is left alone.

  Each step is a row in cases.db, written before the effect and after it, so a
  restart resumes from the row: an interrupted verification runs again (it only
  reads the candidate), an unsent planner mirror is sent again, and a model task
  is never replayed. Nothing here cancels a case, merges or pushes.
  """
  use GenServer
  require Logger
  alias Trailblazer.{Backstop, CaseStore, Config, Events}
  alias Trailblazer.Loop.{CaseRecord, Check}
  alias Trailblazer.Vortex.Store

  @default_deadline_ms 4 * 60 * 60 * 1000
  @check_limit_ms 60 * 60 * 1000

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Every assignment row."
  def list, do: CaseStore.transaction(&rows/1)

  @doc """
  Records the card for a newly admitted case. Called inside `Store.admit`'s
  transaction, so the association is durable before the accepted reply.
  """
  def record(conn, case_id, %{ref: ref} = planner) do
    schema(conn)
    deadline = System.os_time(:millisecond) + (planner[:deadline_ms] || @default_deadline_ms)

    query(
      conn,
      :planner_record,
      "INSERT OR IGNORE INTO planner_assignment (case_id, ref, state, deadline_at, note) VALUES (?, ?, 'open', ?, '')",
      [case_id, ref, deadline]
    )

    :ok
  end

  @impl true
  def init(opts) do
    state = %{
      planner: opts[:planner] || {Path.expand("~/.local/bin/planner"), []},
      tasks: opts[:tasks] || Trailblazer.Planner.Tasks,
      check_limit_ms: opts[:check_limit_ms] || @check_limit_ms,
      mirror_limit_ms: opts[:mirror_limit_ms] || 60_000,
      running: %{},
      deadlines: %{}
    }

    Events.subscribe(:planner)
    {:ok, state, {:continue, :restore}}
  end

  @impl true
  def handle_continue(:restore, state), do: {:noreply, Enum.reduce(list(), state, &resume/2)}

  @impl true
  def handle_info({:trailblazer_event, :planner, {:assigned, id}}, state),
    do: {:noreply, with_row(id, nil, state, &resume/2)}

  def handle_info({:trailblazer_event, {:case, id}, %{closed: true}}, state) do
    state = disarm(state, id)
    {:noreply, with_row(id, "open", state, &closed/2)}
  end

  # The deadline is a Backstop (the only timer, design §13.2): its firing is
  # an anomaly that starts an investigation, never a retry.
  def handle_info({:backstop, ref, _anomaly}, state) do
    case Enum.find(state.deadlines, fn {_, r} -> r == ref end) do
      nil -> {:noreply, state}
      {id, _} -> {:noreply, deadline(id, %{state | deadlines: Map.delete(state.deadlines, id)})}
    end
  end

  # A verification task's result.
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.running, ref) do
      {nil, _} ->
        {:noreply, state}

      {row, running} ->
        state = %{state | running: running}

        case result do
          {:ok, evidence} -> {:noreply, finish(row, "done", evidence, state)}
          {:error, reason} -> {:noreply, finish(row, "block", reason, state)}
        end
    end
  end

  # A verification task that crashed: record the crash as the reason rather
  # than leave the card in doing.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.running, ref) do
      {nil, _} ->
        {:noreply, state}

      {row, running} ->
        state = %{state | running: running}

        {:noreply,
         finish(row, "block", "Independent verification crashed: #{inspect(reason)}", state)}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  ## Steps

  defp deadline(id, state) do
    with_row(id, "open", state, fn row, state ->
      if case_status(id) == "open" do
        at = row.deadline_at |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

        finish(
          row,
          "block",
          "No result by the deadline #{at}; investigate case #{id}. Not retried or cancelled.",
          state
        )
      else
        closed(row, state)
      end
    end)
  end

  defp with_row(id, wanted, state, fun) do
    case Enum.find(list(), &(&1.case_id == id and (wanted == nil or &1.state == wanted))) do
      nil -> state
      row -> fun.(row, state)
    end
  end

  # On start or admission: an open case gets its subscription and deadline, a
  # closed one goes on to its result, an interrupted step is taken again.
  defp resume(%{state: "open"} = row, state) do
    Events.subscribe({:case, row.case_id})

    if case_status(row.case_id) == "open" do
      delay = max(row.deadline_at - System.os_time(:millisecond), 1)

      if Map.has_key?(state.deadlines, row.case_id) do
        state
      else
        ref =
          Backstop.arm(:planner_deadline, row.case_id, {:ms, delay}, fn -> %{ref: row.ref} end)

        put_in(state.deadlines[row.case_id], ref)
      end
    else
      closed(row, state)
    end
  end

  defp resume(%{state: "verifying"} = row, state), do: verify(row, state)

  defp resume(%{state: "mirror_" <> action} = row, state),
    do: mirror(row, action, row.note, state)

  defp resume(_row, state), do: state

  defp closed(row, state) do
    record = CaseRecord.get(row.case_id)
    report = (record && record.report) || %{}

    if record && record.status == "fixed" && field(report, :commit) do
      verify(row, state)
    else
      summary = field(report, :summary) || "case #{row.case_id} closed #{record && record.status}"
      finish(row, "block", "Trailblazer did not return a fixed candidate: #{summary}", state)
    end
  end

  defp verify(row, state) do
    if Enum.any?(state.running, fn {_, r} -> r.case_id == row.case_id end) do
      state
    else
      set(row.case_id, "verifying", "")
      request = Store.get(row.case_id)
      record = CaseRecord.get(row.case_id)
      limit = state.check_limit_ms

      %Task{ref: ref} =
        Task.Supervisor.async_nolink(state.tasks, fn -> check(request, record, limit) end)

      %{state | running: Map.put(state.running, ref, row)}
    end
  end

  # The repo and check come from the admitted request (the repo policy admitted
  # the check); it runs in a detached worktree of the reported commit.
  defp check(request, record, limit) do
    task = if is_binary(request.task), do: Jason.decode!(request.task), else: request.task
    repo = field(task, :repo)
    command = field(task, :check)
    commit = field(record.report, :commit)
    branch = "trailblazer/" <> record.id

    with true <- is_binary(commit) and Regex.match?(~r/\A[0-9a-f]{40}\z/, commit),
         {:ok, ^commit} <- git(repo, ["rev-parse", "refs/heads/" <> branch]) do
      root = Path.join([Config.get(:state_dir), "planner-verification", record.id])

      try do
        with :ok <- File.mkdir_p(Path.dirname(root)),
             :ok <- remove_interrupted_worktree(repo, root),
             {:ok, _} <- git(repo, ["worktree", "add", "--detach", root, commit]) do
          for dir <- ~w(node_modules deps),
              File.dir?(Path.join(repo, dir)),
              do: File.ln_s(Path.join(repo, dir), Path.join(root, dir))

          result = Check.run(root, command, timeout: limit)

          tail =
            result.output_tail
            |> String.slice(-900, 900)
            |> String.replace(root, "<verification-worktree>")

          cond do
            result.status != :pass ->
              {:error,
               "Independent verification failed (#{result.status}, exit #{inspect(result.exit)}): #{command}. #{tail}"}

            true ->
              case git(root, ["status", "--porcelain", "--untracked-files=no"]) do
                {:ok, ""} ->
                  {:ok,
                   "Independent verification passed (exit 0): #{command}. Candidate #{commit} on #{branch}; not merged. #{tail}"}

                {:ok, _} ->
                  {:error, "Independent verification changed tracked candidate files."}

                {:error, reason} ->
                  {:error,
                   "Independent verification status failed: #{String.slice(reason, -300, 300)}"}
              end
          end
        end
      after
        git(repo, ["worktree", "remove", "--force", root])
      end
    else
      _ -> {:error, "The case's reported commit does not match its branch #{branch}."}
    end
  end

  defp remove_interrupted_worktree(repo, root) do
    existed = File.exists?(root)

    case git(repo, ["worktree", "remove", "--force", root]) do
      {:ok, _} -> :ok
      {:error, _} when not existed -> :ok
      {:error, reason} -> {:error, "Interrupted verification cleanup failed: #{reason}"}
    end
  end

  # Intent first (the row names the mirror it owes), then the planner call. A
  # failed call stays pending and is sent again on the next start.
  defp finish(row, action, text, state) do
    set(row.case_id, "mirror_" <> action, text)
    mirror(row, action, text, state)
  end

  defp mirror(row, action, text, state) do
    args =
      case action do
        "done" -> ["--actor", "trailblazer", "done", row.ref, "--evidence", text]
        "block" -> ["--actor", "trailblazer", "block", row.ref, text]
      end

    case run_planner(state.planner, args, state.mirror_limit_ms) do
      :ok ->
        set(row.case_id, action, text)
        # the brain (and any other planner listener) wakes on the durable state
        Events.publish(:planner, {:mirrored, row.ref, action})

      {:error, reason} ->
        Logger.warning(
          "trailblazer: planner #{action} for #{row.ref} failed: #{reason}; sent again on restart"
        )
    end

    state
  end

  ## Helpers

  defp disarm(state, id) do
    case Map.pop(state.deadlines, id) do
      {nil, _} -> state
      {ref, deadlines} -> Backstop.disarm(ref) && %{state | deadlines: deadlines}
    end
  end

  defp run_planner({cmd, extra}, args, limit) do
    path = Enum.join([Path.expand("~/.local/bin"), System.get_env("PATH", "")], ":")
    command = Enum.map_join(["env", "PATH=" <> path, cmd] ++ extra ++ args, " ", &shell_quote/1)

    case Check.run(File.cwd!(), command, timeout: limit) do
      %{status: :pass} -> :ok
      result -> {:error, "#{result.status}: #{String.slice(result.output_tail, -300, 300)}"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp case_status(id) do
    case CaseRecord.get(id, inline: false) do
      %{status: status} -> status
      _ -> "missing"
    end
  end

  defp field(nil, _), do: nil
  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp git(dir, args) do
    case System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args,
           cd: dir,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, String.trim(out)}
    end
  end

  defp set(id, state, note) do
    CaseStore.transaction(fn conn ->
      schema(conn)

      query(
        conn,
        :planner_set,
        "UPDATE planner_assignment SET state = ?, note = ? WHERE case_id = ?",
        [state, note, id]
      )
    end)
  end

  defp rows(conn) do
    schema(conn)

    for [id, ref, state, deadline, note] <-
          query(
            conn,
            :planner_rows,
            "SELECT case_id, ref, state, deadline_at, note FROM planner_assignment",
            []
          ),
        do: %{case_id: id, ref: ref, state: state, deadline_at: deadline, note: note}
  end

  # Lazy DDL, as for repair_lifecycle: works when hot-loaded into an existing store.
  defp schema(conn),
    do:
      query(
        conn,
        :planner_schema,
        "CREATE TABLE IF NOT EXISTS planner_assignment (case_id TEXT PRIMARY KEY, ref TEXT NOT NULL, state TEXT NOT NULL, deadline_at INTEGER NOT NULL, note TEXT NOT NULL)",
        []
      )

  defp query(conn, name, sql, params) do
    {_, %Exqlite.Result{rows: rows}} =
      Exqlite.prepare_execute!(conn, name, sql, params, timeout: :infinity)

    rows || []
  end
end
