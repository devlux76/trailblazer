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

  alias Trailblazer.{Anomaly, Config, EmbedGate, Files, Model, Trail}
  alias Trailblazer.Loop.{CaseRecord, Check, Edits, Lifecycle, Prompts, Tools, Workspace}

  @attempts 3
  @tool_rounds 6
  @files_chars 60_000
  @tally {__MODULE__, :tally}

  @doc """
  Runs `task` (design §7.1: `repo`, `request`, and optionally `files`,
  `design`, `check`, `from`) and gives the report (§7.6). `opts[:case_id]`
  is a case already opened for the task (the API opens it before queueing).
  """
  @spec run(map(), keyword()) :: map()
  def run(task, opts \\ []) do
    task = normalize(task)

    Process.put(@tally, %{
      model_calls: 0,
      prompt_tokens: 0,
      completion_tokens: 0,
      coder_calls: 0,
      changed: [],
      check: nil,
      ws: nil,
      workspace_closed: false
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
        e -> crashed(%{st | ws: tally(:ws)}, Exception.format(:error, e, __STACKTRACE__))
      catch
        :throw, {:lifecycle_error, reason} ->
          report(%{st | ws: tally(:ws)}, :failed, "Lifecycle failed: #{inspect(reason)}.")

        kind, reason ->
          crashed(%{st | ws: tally(:ws)}, Exception.format(kind, reason, __STACKTRACE__))
      end

    _ = Lifecycle.reported(id, report)

    case CaseRecord.close(id, report) do
      :ok -> Logger.info("trailblazer: case #{id} report #{brief(:report, report)}")
      error -> Logger.error("trailblazer: case #{id} could not be closed: #{inspect(error)}")
    end

    Process.delete(@tally)
    report
  end

  ## Stages

  # The trail is built from the repository, not the worktree, so it is built
  # while the worktree is made and provisioned (design §13.4).
  defp work(st) do
    trail_job = job(fn -> trail(st) end)

    case open_workspace(st) do
      {:ok, st} ->
        trail = await_job(trail_job, st)
        files = files(st)
        check = st.task.check || mod(st, :check, Check).default(st.ws.path)
        pattern = pattern(st)

        st =
          Map.put(st, :head, %{
            check: check,
            pattern: pattern,
            evidence: Trailblazer.Loop.DependencyEvidence.gather(st.task)
          })

        record(st, :attempt, %{
          stage: :plan,
          check: check,
          files: Enum.map(files, &elem(&1, 0)),
          pattern: pattern && elem(pattern, 0)
        })

        attempts(st, trail, files, check, 1, nil)

      {:error, reason} ->
        stop_job(trail_job)
        record(st, :error, %{stage: :workspace, reason: reason})
        report(st, :failed, "No worktree could be made: #{describe(reason)}.")

      {:error, st, reason} ->
        stop_job(trail_job)
        record(st, :error, %{stage: :provision, reason: reason})

        report(
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

  defp await_job({token, _pid, mon}, st) do
    receive do
      {^token, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, _pid, reason} ->
        record(st, :attempt, %{stage: :trail, error: Exception.format_exit(reason)})
        ""
    end
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

    # files given in full are not repeated in the trail, and a task that names
    # its files needs a short trail (T1 of L9: 72% of the prompt, mostly noise)
    opts =
      query_opts(st)
      |> Keyword.merge(files: files, omit: files)
      |> Keyword.put_new(
        :budget,
        if(files == [], do: Config.get(:trail_tokens), else: Config.get(:loop_trail_tokens))
      )

    case build.(st.task.repo, st.task.request, opts) do
      %{text: text} = trail ->
        record(st, :attempt, %{stage: :trail, text: text, notes: Map.get(trail, :notes, [])})
        text

      {:error, reason} ->
        record(st, :attempt, %{stage: :trail, error: reason})
        ""
    end
  end

  # The files the caller named, from the worktree, in full while they fit
  # (H1: a huge file does not crowd out the trail; `read` gives the rest).
  defp files(st) do
    {files, _left} =
      Enum.flat_map_reduce(st.task.files, @files_chars, fn path, left ->
        case Files.read(st.ws.path, path) do
          {:ok, text} when byte_size(text) <= left -> {[{path, text}], left - byte_size(text)}
          {:ok, _big} -> {[{path, "(too long to show in full: use the read tool)\n"}], left}
          {:error, _} -> {[{path, "(no such file in the repository)\n"}], left}
        end
      end)

    files
  end

  # The head start's test to follow (design §6.5): when the request asks for
  # a test and no file the caller named is one, the test of a named file, or
  # else the repository's smallest test as its conventions, within 6 KB.
  @test_path ~r{(^|/)(tests?|spec|__tests__)/|[._-](test|spec)\.[a-z]+$|_test\.exs?$|(^|/)test_[^/]+\.py$}
  @pattern_bytes 6_000

  defp pattern(st) do
    named = st.task.files

    if Regex.match?(~r/\btests?\b/i, st.task.request) and
         not Enum.any?(named, &Regex.match?(@test_path, &1)) do
      stems = MapSet.new(named, &stem/1)
      tests = st.ws.path |> tracked() |> Enum.filter(&Regex.match?(@test_path, &1))

      candidates =
        case Enum.filter(tests, &MapSet.member?(stems, stem(&1))) do
          [] -> Enum.sort_by(tests, &file_size(st.ws.path, &1))
          own -> own
        end

      Enum.find_value(candidates, fn path ->
        case Files.read(st.ws.path, path) do
          {:ok, text} when byte_size(text) <= @pattern_bytes -> {path, text}
          _ -> nil
        end
      end)
    end
  end

  # The coder prompt's bytes by section, so budgets are tuned against the
  # record (design §6.5.4): %{"system" => n, "Trail" => n, ...}.
  defp prompt_sizes([%{content: system}, %{content: user}]) do
    user
    |> String.split(~r/^## /m)
    |> Enum.reject(&(&1 == ""))
    |> Map.new(fn part -> {part |> String.split("\n", parts: 2) |> hd(), byte_size(part)} end)
    |> Map.put("system", byte_size(system))
  end

  defp prompt_sizes(messages), do: %{"total" => messages |> inspect() |> byte_size()}

  defp stem(path) do
    path
    |> Path.basename()
    |> String.replace(~r/^test_|([._-](test|spec))?(\.[a-z0-9]+)+$|_test$/i, "")
    |> String.downcase()
  end

  defp file_size(root, path) do
    case File.stat(Path.join(root, path)) do
      {:ok, %{size: size}} -> size
      _ -> :infinity
    end
  end

  defp attempts(st, _trail, _files, _check, n, _feedback) when n > @attempts, do: exhausted(st)

  defp attempts(st, trail, files, check, n, feedback) do
    record(st, :attempt, %{stage: :attempt, n: n})
    tally(:changed, [])

    case attempt(st, trail, files, check, feedback) do
      {:ok, reply} ->
        succeeded(st, n, reply, check)

      {:retry, why, next_feedback} ->
        failure = %{n: n, why: why, feedback: next_feedback, changed: tally(:changed)}
        st = %{st | failures: st.failures ++ [failure]}

        # the last attempt's edits stay in the worktree for inspection
        case if(n < @attempts, do: mod(st, :workspace, Workspace).reset(st.ws), else: :ok) do
          :ok ->
            next_feedback =
              if n < @attempts do
                next_feedback <>
                  "\n\nThe worktree was reset to its original files; all previous edits were discarded. " <>
                  "Apply your complete corrected change to the original files shown above."
              else
                next_feedback
              end

            attempts(st, trail, files, check, n + 1, next_feedback)

          {:error, reason} ->
            record(st, :error, %{stage: :reset, reason: reason})

            report(
              st,
              :failed,
              "The worktree could not be reset after attempt #{n}: #{describe(reason)}.",
              %{attempts: n}
            )
        end

      {:stop, report} ->
        report
    end
  end

  defp attempt(st, trail, files, check, feedback) do
    messages = Prompts.coder(st.task, trail, files, feedback, Map.get(st, :head, %{}))
    record(st, :attempt, %{stage: :prompt_size, bytes: prompt_sizes(messages)})

    with {:ok, reply} <- converse(st, messages, Tools.definitions(), :coder),
         {:ok, blocks} <- blocks(st, reply),
         :ok <- apply_edits(st, blocks),
         :ok <- run_check(st, check),
         :ok <- review(st) do
      {:ok, reply}
    end
  end

  ## The model

  # One exchange: the model may call tools for up to @tool_rounds rounds,
  # then must answer without them.
  defp converse(st, messages, tools, role, round \\ 1) do
    {tools_now, messages} =
      cond do
        tools == nil ->
          {nil, messages}

        round <= @tool_rounds ->
          {tools, messages}

        true ->
          {nil,
           messages ++
             [
               %{
                 role: "user",
                 content: "No more tool calls. Answer now with your SEARCH/REPLACE blocks."
               }
             ]}
      end

    case chat(st, messages, tools_now, role) do
      {:ok, %{tool_calls: [_ | _] = calls} = reply} when tools_now != nil ->
        assistant = %{
          role: "assistant",
          content: reply.content,
          tool_calls:
            Enum.map(calls, fn c ->
              %{id: c.id, type: "function", function: %{name: c.name, arguments: c.arguments}}
            end)
        }

        answers = Enum.map(calls, &answer_tool(st, &1))
        converse(st, messages ++ [assistant | answers], tools, role, round + 1)

      other ->
        other
    end
  end

  defp answer_tool(st, call) do
    target = %{repo: st.task.repo, worktree: st.ws.path}
    result = mod(st, :tools, Tools).call(target, call.name, call.arguments, query_opts(st))

    record(st, :tool_call, %{
      id: call.id,
      name: call.name,
      arguments: call.arguments,
      result: result
    })

    %{role: "tool", tool_call_id: call.id, content: result}
  end

  defp chat(st, messages, tools, role) do
    record(st, :prompt, %{role: role, messages: messages, tools: tools != nil})

    # a call that fails part way keeps what it had (E5)
    partial = fn reply -> record(st, :reply, Map.merge(reply, %{role: role, partial: true})) end

    # a coder call after the first (a retry, a tool round) extends a prompt the
    # model server has seen, so its prefix should come from the cache (E25)
    expect_cache? = role == :coder and tally(:coder_calls) > 0
    if role == :coder, do: tally(:coder_calls, tally(:coder_calls) + 1)

    opts = [
      on_partial: partial,
      on_delta: stream_log(st, role),
      on_progress: progress_log(st, role, expect_cache?)
    ]

    opts = opts ++ if(tools, do: [tools: tools], else: [])
    opts = opts ++ Keyword.get(st.opts, :model_opts, [])

    case with_gate(st, fn -> mod(st, :model, Model).chat(messages, opts) end) do
      {:ok, reply} ->
        record(st, :reply, Map.put(reply, :role, role))
        usage = Map.get(reply, :usage) || %{}
        tally(:model_calls, tally(:model_calls) + 1)
        tally(:prompt_tokens, tally(:prompt_tokens) + (usage[:prompt_tokens] || 0))
        tally(:completion_tokens, tally(:completion_tokens) + (usage[:completion_tokens] || 0))
        {:ok, reply}

      {:error, :model_down} ->
        record(st, :error, %{stage: role, reason: :model_down})
        {:stop, report(st, :failed, "The code model is not running.")}

      {:error, {:http, status}} ->
        record(st, :error, %{stage: role, reason: {:http, status}})
        {:stop, report(st, :failed, "The code model answered HTTP #{status}.")}

      {:error, reason} ->
        tally(:model_calls, tally(:model_calls) + 1)
        record(st, :error, %{stage: role, reason: reason})

        {:retry, {:model, reason},
         "Your last reply was not usable (#{describe(reason)}). Answer more briefly: a sentence, then the blocks."}
    end
  end

  defp with_gate(st, fun) do
    case Keyword.get(st.opts, :gate, {&EmbedGate.hold/0, &EmbedGate.release/0}) do
      false ->
        fun.()

      {hold, release} ->
        :ok = hold.()

        try do
          fun.()
        after
          release.()
        end
    end
  end

  ## Edits, check and review

  defp blocks(st, %{finish_reason: "length"}) do
    record(st, :edit, %{status: :cut_off})

    {:retry, :cut_off,
     "Your reply was cut off before it ended. Send fewer, shorter SEARCH/REPLACE blocks."}
  end

  defp blocks(st, reply) do
    case Edits.parse(reply.content) do
      {:ok, []} ->
        record(st, :edit, %{status: :no_blocks})

        {:retry, :no_blocks,
         "Your reply had no SEARCH/REPLACE blocks. Make the change with blocks in the format given."}

      {:ok, blocks} ->
        {:ok, blocks}

      {:error, message} ->
        record(st, :edit, %{status: :unparsed, error: message})
        {:retry, :unparsed, "Your blocks could not be read:\n\n#{message}"}
    end
  end

  defp apply_edits(st, blocks) do
    case Edits.apply(st.ws.path, blocks,
           files: tracked(st.ws.path),
           shown: Map.get(st.task, :files, [])
         ) do
      {:ok, paths} ->
        record(st, :edit, %{status: :applied, blocks: blocks, paths: paths})
        tally(:changed, paths)
        :ok

      {:error, failures} ->
        record(st, :edit, %{status: :missed, blocks: blocks, failures: failures})
        {:retry, :edits_missed, Edits.feedback(failures)}
    end
  end

  defp tracked(path) do
    case System.cmd("git", ["ls-files", "-z"], cd: path, stderr_to_stdout: true) do
      {out, 0} -> String.split(out, "\0", trim: true)
      _ -> []
    end
  end

  defp run_check(_st, nil), do: :ok

  defp run_check(st, command) do
    tree = Lifecycle.tree(st.ws, tally(:changed))

    result =
      mod(st, :check, Check).run(st.ws.path, command, Keyword.get(st.opts, :check_opts, []))

    result = Map.merge(result, %{command: command, tree: tree})
    record(st, :check, result)
    lifecycle(Lifecycle.record_check(st.id, result))
    tally(:check, result)

    case result.status do
      :pass ->
        :ok

      status ->
        {:retry, {:check, status},
         "The check `#{command}` #{if status == :timeout, do: "timed out", else: "failed"}. " <>
           "The end of its output:\n\n#{result.output_tail}"}
    end
  end

  # A review in a fresh context: the request, the design and the diff only.
  # An answer that is neither PASS nor FAIL is asked for once more (D13).
  defp review(st) do
    diff = mod(st, :workspace, Workspace).diff(st.ws, tally(:changed))
    messages = Prompts.reviewer(st.task, diff, st.head.evidence)

    with {:ok, reply} <- converse(st, messages, nil, :reviewer),
         {:ok, verdict, text} <- verdict(st, messages, reply) do
      record(st, :review, %{verdict: verdict_name(verdict), text: text})

      case verdict do
        :pass ->
          :ok

        {:fail, findings} ->
          {:retry, :review, "The review of your change found:\n\n#{findings}"}

        {:unclear, _} ->
          {:retry, :review_unclear,
           "The review could not tell whether your change is right. Make it smaller and plainer."}
      end
    end
  end

  defp verdict(st, messages, reply) do
    case judged(reply) do
      {:unclear, _} ->
        again =
          messages ++
            [
              %{role: "assistant", content: reply.content},
              %{role: "user", content: "Answer with exactly PASS, or FAIL: and the findings."}
            ]

        with {:ok, second} <- converse(st, again, nil, :reviewer) do
          {:ok, judged(second), second.content}
        end

      verdict ->
        {:ok, verdict, reply.content}
    end
  end

  # a review cut off at the length limit may say PASS and mean nothing
  defp judged(%{finish_reason: "length", content: text}), do: {:unclear, text}
  defp judged(reply), do: Prompts.review_verdict(reply.content)

  defp verdict_name(:pass), do: :pass
  defp verdict_name({kind, _}), do: kind

  ## Endings

  defp succeeded(st, n, reply, check) do
    workspace = mod(st, :workspace, Workspace)
    # a reply of blocks alone (the third live trial) still gets a summary
    explanation =
      case explanation(reply.content) do
        "" -> "Changed #{Enum.join(tally(:changed), ", ")}."
        text -> text
      end

    extra = %{files: tally(:changed), attempts: n}

    cond do
      check == nil ->
        report(
          st,
          :unverified,
          "Changed and reviewed, but there is no check, so it is left uncommitted in the worktree. #{explanation}",
          extra
        )

      true ->
        message = "#{first_line(st.task.request)}\n\n#{explanation}\n\nTrailblazer case #{st.id}"

        evidence = tally(:check)
        current_tree = Lifecycle.tree(st.ws, tally(:changed))

        commit =
          if evidence.tree == current_tree do
            with {:ok, _} <- Lifecycle.prepare_commit(st.id, current_tree, evidence),
                 do: workspace.commit(st.ws, message, tally(:changed))
          else
            {:error,
             "the candidate changed after its trusted check; use a check that does not rewrite tracked files"}
          end

        case commit do
          {:ok, sha} ->
            journal = lifecycle(Lifecycle.reconcile(st.id))

            if journal["candidate"] == sha do
              summary =
                case close_candidate(st, workspace) do
                  :ok ->
                    explanation

                  {:error, reason} ->
                    explanation <> " Candidate workspace cleanup blocked: #{inspect(reason)}."
                end

              report(st, :fixed, summary, Map.put(extra, :commit, sha))
            else
              report(
                st,
                :failed,
                "The commit could not be reconciled with its checked tree.",
                extra
              )
            end

          {:error, reason} ->
            _ = Lifecycle.failed(st.id, reason)

            report(
              st,
              :failed,
              "Check and review passed, but the commit failed: #{describe(reason)}.",
              extra
            )
        end
    end
  end

  defp lifecycle({:ok, record}), do: record
  defp lifecycle({:error, reason}), do: throw({:lifecycle_error, reason})

  defp close_candidate(st, workspace) do
    result =
      with {:ok, _} <- Lifecycle.prepare_candidate_removal(st.id),
           :ok <- workspace.close(st.ws),
           {:ok, %{"cleanup" => "candidate_workspace_removed"}} <- Lifecycle.reconcile(st.id),
           do: :ok

    case result do
      :ok ->
        tally(:workspace_closed, true)
        :ok

      other ->
        reason =
          case other do
            {:error, reason} -> reason
            _ -> :candidate_removal_not_observed
          end

        Lifecycle.failed(st.id, reason)
        {:error, reason}
    end
  end

  defp exhausted(st) do
    diagnosis =
      st.failures
      |> Enum.map(&describe(&1.why))
      |> Enum.frequencies()
      |> Enum.map_join(", ", fn {why, count} -> "#{why} (#{count})" end)

    dossier =
      Prompts.dossier(%{
        case: st.id,
        request: st.task.request,
        from: st.task.from,
        repo: st.task.repo,
        branch: st.ws.branch,
        worktree: st.ws.path,
        trail: "(in the case record)",
        attempts:
          Enum.map(st.failures, fn f ->
            %{n: f.n, summary: changed_summary(f.changed), failure: f.feedback}
          end),
        diagnosis: "All #{@attempts} attempts failed: #{diagnosis}."
      })

    record(st, :dossier, %{text: dossier})

    report(
      st,
      :failed,
      "#{@attempts} attempts failed: #{diagnosis}. The dossier says what was tried.",
      %{
        attempts: @attempts,
        dossier: dossier,
        files: tally(:changed)
      }
    )
  end

  defp changed_summary([]), do: nil
  defp changed_summary(paths), do: Enum.join(paths, ", ")

  defp crashed(st, text) do
    Logger.error("trailblazer: case #{st.id} crashed: #{text}")
    _ = CaseRecord.event(st.id, :error, %{stage: :crash, error: text})
    report(st, :failed, "Trailblazer failed inside the loop; the case record has the error.")
  end

  defp report(st, status, summary, extra \\ %{}) do
    check =
      case tally(:check) do
        nil -> nil
        %{status: :pass} -> %{status: :pass}
        %{status: s} = c -> %{status: s, output_tail: c.output_tail}
      end

    report = %{
      status: status,
      summary: summary,
      branch: st.ws && st.ws.branch,
      commit: extra[:commit],
      worktree: if(st.ws && tally(:workspace_closed) != true, do: st.ws.path),
      files: extra[:files] || [],
      check: check,
      attempts: extra[:attempts] || length(st.failures),
      cost: %{
        model_calls: tally(:model_calls),
        prompt_tokens: tally(:prompt_tokens),
        completion_tokens: tally(:completion_tokens),
        seconds: div(now() - st.started, 1000)
      },
      case: st.id
    }

    if extra[:dossier], do: Map.put(report, :dossier, extra[:dossier]), else: report
  end

  ## Helpers

  # a record that cannot be written stops the task: no case is kept partially;
  # each one is also logged as it happens, so a run can be followed live
  defp record(st, kind, data) do
    :ok = CaseRecord.event(st.id, kind, data)
    Logger.info("trailblazer: case #{st.id} #{kind} #{brief(kind, data)}")
  end

  defp brief(:prompt, data), do: "#{data[:role]}, #{length(data[:messages] || [])} messages"

  defp brief(:reply, data) do
    "#{data[:role]}#{if data[:partial], do: " (partial)"} finish=#{data[:finish_reason]} " <>
      "#{data[:ms]} ms, reasoning #{byte_size(data[:reasoning] || "")} B, " <>
      "content #{inspect(String.slice(data[:content] || "", 0, 200))}"
  end

  defp brief(_, data),
    do: data |> inspect(printable_limit: 200, limit: 20) |> String.slice(0, 400)

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
  defp progress_log(st, role, expect_cache?) do
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

  defp stream_log(st, role) do
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

  defp tally(key), do: Process.get(@tally, %{}) |> Map.get(key, 0)
  defp tally(key, value), do: Process.put(@tally, Map.put(Process.get(@tally, %{}), key, value))

  defp mod(st, key, default), do: Keyword.get(st.opts, key, default)
  defp query_opts(st), do: Keyword.get(st.opts, :query_opts, [])
  defp now, do: System.monotonic_time(:millisecond)

  defp normalize(task) do
    get = fn key -> task[key] || task[to_string(key)] end

    %{
      repo: get.(:repo),
      request: get.(:request),
      files: get.(:files) || [],
      design: get.(:design),
      check: get.(:check),
      primary: get.(:primary),
      from: get.(:from) || "cli"
    }
  end

  # What the model said before its first block, in a few lines.
  defp explanation(content) do
    content
    # the fence is optional, as in `Edits`: live T3 wrote `path` then SEARCH
    |> String.split(~r/^[^\n]*\n(?:```[^\n]*\n)?<{5,9} SEARCH/m, parts: 2)
    |> hd()
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(&1, "```")))
    |> Enum.take(-3)
    |> Enum.join(" ")
    |> String.slice(0, 500)
  end

  defp first_line(text),
    do: text |> String.trim() |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 72)

  defp describe(reason) when is_binary(reason), do: reason

  defp describe(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp describe({:check, status}), do: "check #{status}"
  defp describe({:model, reason}), do: "model #{describe(reason)}"

  defp describe({:backstop, id}),
    do: "it did not finish within its backstop (anomaly #{id})"

  defp describe({:backstop, id, late: _}),
    do: "it finished only as its backstop fired (anomaly #{id})"

  defp describe(reason), do: inspect(reason)
end
