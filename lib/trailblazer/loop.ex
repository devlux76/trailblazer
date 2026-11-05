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

  alias Trailblazer.{Anomaly, Backstop, Config, EmbedGate, Files, Model, Trail}

  alias Trailblazer.Loop.{
    Artifacts,
    CaseRecord,
    Check,
    CompiledCheckpoint,
    Edits,
    Lifecycle,
    Prompts,
    Tools,
    Workspace
  }

  @attempts 3
  @tool_rounds 6
  @tally {__MODULE__, :tally}

  @doc """
  Runs `task` (design §7.1: `repo`, `request`, and optionally `files`,
  `design`, `check`, `from`, `read_rounds` from 0 to 6) and gives the report (§7.6). `opts[:case_id]`
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
        e -> crashed(%{st | ws: tally(:ws)}, Exception.format(:error, e, __STACKTRACE__))
      catch
        :throw, {:lifecycle_error, reason} ->
          report(%{st | ws: tally(:ws)}, :failed, "Lifecycle failed: #{inspect(reason)}.")

        kind, reason ->
          crashed(%{st | ws: tally(:ws)}, Exception.format(kind, reason, __STACKTRACE__))
      end

    _ = Lifecycle.reported(id, report)
    report = coordinate(id, report, opts)

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

    # the named files seed the trail, and their chunks reach the model through
    # it like any other: a file is never sent whole, the model reads the rest
    opts =
      query_opts(st)
      |> Keyword.merge(files: files)
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
        {:ok, text} -> {path, lines(text)}
        {:error, _} -> {path, :missing}
      end
    end)
  end

  defp lines(""), do: 0
  defp lines(text), do: length(String.split(String.trim_trailing(text, "\n"), "\n"))

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

  defp attempts(%{task: %{replay_reply_from: source}} = st, _trail, _files, _check, n, _feedback)
       when is_binary(source) and n > 1, do: exhausted(st)

  defp attempts(st, trail, files, check, n, feedback) do
    record(st, :attempt, %{stage: :attempt, n: n})
    tally(:changed, [])
    tally(:previous_edits, nil)
    tally(:relocations, [])
    tally(:artifacts, nil)

    case attempt(st, trail, files, check, feedback) do
      {:ok, reply} ->
        succeeded(st, n, reply, check)

      {:awaiting_review, reason} ->
        awaiting_review(st, reason)

      {:retry, why, next_feedback} ->
        next_feedback =
          Enum.map_join(Enum.reverse(tally(:relocations)), "", &Edits.relocation_notice/1) <>
            next_feedback

        next_feedback =
          case tally(:previous_edits) do
            [_ | _] = edits ->
              next_feedback <>
                "\n\nPrevious submitted edit blocks (reference only, captured before any check; a missed atomic submission writes no files). " <>
                "Use their exact code to diagnose the failure; still submit corrected edits #{submit_how(st)}.\n\n```json\n" <>
                Jason.encode!(edits, pretty: true) <> "\n```"

            _ ->
              next_feedback
          end

        failure = %{n: n, why: why, feedback: next_feedback, changed: tally(:changed)}
        st = %{st | failures: st.failures ++ [failure]}

        # the last attempt's edits stay in the worktree for inspection
        retry? = n < @attempts and is_nil(st.task.replay_reply_from)

        reset = fn -> if retry?, do: mod(st, :workspace, Workspace).reset(st.ws), else: :ok end

        case with :ok <- checkpoint_attempt(st, n), do: reset.() do
          :ok ->
            next_feedback =
              if retry? do
                next_feedback <>
                  "\n\nThe worktree was reset to its original files; previous edits remain in the attempt checkpoint and case record. " <>
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

  # A generation deadline spans every read, correction and model call in one
  # fresh conversation. Verification time is shared across all three attempts.
  defp attempt(st, trail, files, check, feedback) do
    with {:ok, reply} <- generate(st, trail, files, feedback),
         {:ok, blocks} <- blocks(st, reply),
         :ok <- apply_edits(st, blocks) do
      started = now()
      remaining = verification_remaining(st)
      tally(:phase, {:verification, started + remaining})

      try do
        budget_remaining!()

        result =
          with :ok <- prepare_artifacts(st),
               :ok <- compile_checkpoint(st),
               :ok <- run_check(st, check),
               :ok <- review(st),
               do: {:ok, reply}

        budget_remaining!()
        result
      catch
        :throw, {:budget_expired, :verification} ->
          {:awaiting_review, :verification_budget_exhausted}
      after
        tally(:verification_ms, tally(:verification_ms) + now() - started)
        tally(:phase, nil)
      end
    end
  end

  defp generate(st, trail, files, feedback) do
    limit = Keyword.get(st.opts, :generation_limit_ms, 900_000)
    tally(:phase, {:generation, now() + limit})
    record(st, :attempt, %{stage: :generation_budget, limit_ms: limit})

    try do
      result = coder_reply(st, trail, files, feedback)
      budget_remaining!()
      result
    catch
      :throw, {:budget_expired, :generation} ->
        record(st, :error, %{stage: :generation, reason: :generation_timeout})

        {:retry, :generation_timeout,
         "The 15-minute generation window expired. Start in a fresh context and submit a smaller complete change. Partial output is preserved in the case record."}
    after
      tally(:phase, nil)
    end
  end

  defp verification_remaining(st),
    do: max(0, Keyword.get(st.opts, :verification_limit_ms, 900_000) - tally(:verification_ms))

  defp budget_remaining! do
    {phase, deadline} = tally(:phase)
    remaining = deadline - now()
    if remaining <= 0, do: throw({:budget_expired, phase})
    remaining
  end

  defp verification_opts(st) do
    remaining = budget_remaining!()
    opts = Keyword.get(st.opts, :check_opts, [])

    opts
    |> Keyword.put(:timeout, min(remaining, opts[:timeout] || Config.get(:backstop_check_ms)))
    |> Keyword.put(:deadline_at, System.os_time(:millisecond) + remaining)
  end

  defp checkpoint_attempt(st, n) do
    tree = Lifecycle.tree(st.ws, tally(:changed))
    ref = "refs/trailblazer/attempts/#{st.id}/#{n}"

    case git(st.ws.path, ["update-ref", ref, tree]) do
      {:ok, _} ->
        record(st, :attempt, %{stage: :attempt_checkpoint, n: n, tree: tree, ref: ref})
        :ok

      {:error, reason} ->
        {:error, {:checkpoint_failed, reason}}
    end
  end

  defp coder_reply(%{task: %{replay_reply_from: id}} = st, _trail, _files, _feedback)
       when is_binary(id) do
    with %{status: "failed"} = source <- CaseRecord.get(id),
         true <- source.repo == st.task.repo and source.task["check"] == st.task.check,
         true <- (source.task["from"] || "cli") == st.task.from,
         true <- source.task["artifacts"] == st.task.artifacts,
         %{} = ws <-
           Enum.find(source.events, &(&1.kind == "attempt" and &1.data["stage"] == "workspace")),
         true <- ws.data["base"] == st.ws.base,
         %{} = edit <- Enum.find(Enum.reverse(source.events), &(&1.kind == "edit")),
         true <- edit.data["status"] in ["no_blocks", "unparsed"],
         %{} = event <-
           Enum.find(
             Enum.reverse(source.events),
             &(&1.kind == "reply" and &1.data["role"] == "coder")
           ),
         true <- event.data["finish_reason"] == "stop" and event.data["partial"] != true,
         true <- Map.get(event.data, "tool_calls", []) == [],
         {:ok, edits} <- Tools.text_edit_blocks(event.data["content"]) do
      reply = %{
        content: event.data["content"],
        reasoning: "",
        tool_calls: [],
        edit_blocks: edits,
        finish_reason: "stop",
        usage: %{prompt_tokens: 0, completion_tokens: 0},
        ms: 0,
        replayed_from: id,
        source_reply_seq: event.seq,
        source_reply_sha256:
          :crypto.hash(:sha256, event.data["content"]) |> Base.encode16(case: :lower)
      }

      record(st, :reply, Map.put(reply, :role, :coder))
      {:ok, reply}
    else
      _ ->
        record(st, :error, %{stage: :replay_reply, source: id, reason: :incompatible_source})

        {:stop,
         report(
           st,
           :failed,
           "The recorded reply cannot be replayed for this peer, repository, check, base or response format."
         )}
    end
  end

  defp coder_reply(st, trail, files, feedback) do
    messages = Prompts.coder(st.task, trail, files, feedback, Map.get(st, :head, %{}))
    record(st, :attempt, %{stage: :prompt_size, bytes: prompt_sizes(messages)})

    format =
      if st.task.read_rounds > 0 and st.task.files != [] and
           Enum.all?(files, fn {_, size} -> size != :missing end),
         do: :ranges,
         else: :both

    {format, tools} =
      if st.task.edit_mode == :text,
        do: {:text, Tools.definitions()},
        else: {format, Tools.definitions() ++ [Tools.edit_definition(format)]}

    record(st, :attempt, %{stage: :edit_format, format: format})
    converse(st, messages, tools, :coder)
  end

  ## The model

  # One exchange: the task may reduce the default reading budget,
  # then must submit edits through the remaining edit tool.
  defp converse(st, messages, tools, role, round \\ 1, corrections \\ 0)

  # Text mode: once reading ends the coder answers in plain text, so the
  # final call offers no tools; its SEARCH/REPLACE reply is parsed by blocks/2.
  defp converse(%{task: %{edit_mode: :text}} = st, messages, tools, :coder, round, corrections)
       when tools != nil and round > st.task.read_rounds do
    messages =
      messages ++
        [
          %{
            role: "user",
            content:
              "Reading is complete. Reply now with the complete change as SEARCH/REPLACE blocks only; call no tool."
          }
        ]

    converse(st, messages, nil, :coder, round, corrections)
  end

  defp converse(st, messages, tools, role, round, corrections) do
    submit_only = tools != nil and (round > st.task.read_rounds or corrections > 0)

    messages =
      if submit_only and corrections == 0 do
        messages ++
          [
            %{
              role: "user",
              content:
                "Reading is complete. Call submit_edits alone with the complete batch. No more read or search calls."
            }
          ]
      else
        messages
      end

    case chat(st, messages, tools, role, submit_only) do
      {:ok, %{tool_calls: [_ | _] = calls} = reply} when tools != nil ->
        submissions = Enum.filter(calls, &(&1.name == "submit_edits"))

        cond do
          length(submissions) == 1 and length(calls) == 1 ->
            case Tools.edit_blocks(hd(submissions).arguments) do
              {:ok, blocks} ->
                preview_edits(st, messages, tools, role, round, reply, blocks, corrections)

              {:error, reason} ->
                correct_edits(st, messages, tools, role, round, reply, corrections, reason)
            end

          submissions != [] ->
            correct_edits(
              st,
              messages,
              tools,
              role,
              round,
              reply,
              corrections,
              "Call submit_edits alone, without read/search calls, with the complete batch."
            )

          submit_only ->
            correct_edits(
              st,
              messages,
              tools,
              role,
              round,
              reply,
              corrections,
              "Reading is complete. Only submit_edits may be called now."
            )

          true ->
            answers = Enum.map(calls, &answer_tool(st, &1))

            converse(
              st,
              messages ++ [assistant_message(reply) | answers],
              tools,
              role,
              round + 1,
              corrections
            )
        end

      other ->
        other
    end
  end

  defp assistant_message(reply) do
    %{
      role: "assistant",
      content: reply.content,
      tool_calls:
        Enum.map(reply.tool_calls, fn call ->
          %{
            id: call.id,
            type: "function",
            function: %{name: call.name, arguments: call.arguments}
          }
        end)
    }
  end

  defp preview_edits(st, messages, tools, role, round, reply, blocks, corrections) do
    tally(:previous_edits, blocks)
    record(st, :edit, %{status: :preview, paths: Enum.map(blocks, & &1.path)})

    case Edits.apply(st.ws.path, blocks, [dry_run: true] ++ edit_options(st)) do
      {:ok, _} ->
        record(st, :edit, %{status: :preview_ok, blocks: length(blocks)})
        {:ok, Map.put(reply, :edit_blocks, blocks)}

      {:error, failures} ->
        record(st, :edit, %{
          status: :preview_missed,
          blocks: blocks,
          failures: failures,
          correction: corrections
        })

        case missing_source(st, failures) do
          [] ->
            correct_edits(
              st,
              messages,
              tools,
              role,
              round,
              reply,
              corrections,
              Edits.feedback(failures)
            )

          paths ->
            source_missing(st, paths)
        end
    end
  end

  defp correct_edits(st, messages, tools, role, round, reply, corrections, feedback) do
    answers =
      Enum.map(reply.tool_calls, fn call ->
        record(st, :tool_call, %{
          id: call.id,
          name: call.name,
          arguments: call.arguments,
          result: feedback,
          status: :refused
        })

        %{role: "tool", tool_call_id: call.id, content: feedback}
      end)

    if corrections >= 2 do
      record(st, :edit, %{status: :edit_repair_exhausted, submissions: corrections + 1})

      {:stop,
       report(
         st,
         :failed,
         "edit_repair_exhausted: three unusable submissions; no partial batch was written. Worktree and case evidence retained.",
         %{attempts: length(st.failures) + 1, reason: :edit_repair_exhausted}
       )}
    else
      converse(
        st,
        messages ++ [assistant_message(reply) | answers],
        tools,
        role,
        round,
        corrections + 1
      )
    end
  end

  defp edit_options(st),
    do: [files: tracked(st.ws.path), shown: Map.get(st.task, :files, [])]

  defp missing_source(%{task: %{read_rounds: 0}}, failures) do
    for f <- failures,
        f.reason in [:no_such_file, :no_match] and f.closest == "",
        do: f.block.path
  end

  defp missing_source(_st, _failures), do: []

  defp source_missing(st, paths) do
    record(st, :error, %{stage: :edits, reason: :source_context_missing, paths: paths})

    {:stop,
     report(
       st,
       :failed,
       "source_context_missing: #{Enum.join(paths, ", ")}. Supply literal current anchors or authorize reads on a fresh admission; no zero-read retry was run.",
       %{attempts: length(st.failures) + 1, reason: :source_context_missing}
     )}
  end

  defp answer_tool(st, call) do
    target = %{repo: st.task.repo, worktree: st.ws.path}
    remaining = budget_remaining!()

    result =
      case Backstop.guard(
             :generation_tool,
             st.id,
             {:ms, remaining},
             fn -> %{tool: call.name} end,
             fn ->
               mod(st, :tools, Tools).call(target, call.name, call.arguments, query_opts(st))
             end
           ) do
        {:ok, result} -> result
        {:error, {:backstop, _}} -> throw({:budget_expired, :generation})
        {:error, reason} -> "Tool failed: #{inspect(reason)}"
      end

    budget_remaining!()

    record(st, :tool_call, %{
      id: call.id,
      name: call.name,
      arguments: call.arguments,
      result: result
    })

    %{role: "tool", tool_call_id: call.id, content: result}
  end

  defp chat(st, messages, tools, role, submit_only) do
    # The pinned server's required choice allows any advertised tool. Remove
    # reading tools when the host no longer permits them, including corrections.
    tools =
      if submit_only,
        do: Enum.filter(tools, &(&1.function.name == "submit_edits")),
        else: tools

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

    opts =
      if submit_only,
        do: opts ++ [tool_choice: "required"],
        else: opts

    opts =
      if is_nil(st.task.reasoning_budget_tokens),
        do: opts,
        else: opts ++ [reasoning_budget_tokens: st.task.reasoning_budget_tokens]

    role_opts =
      case role do
        :reviewer ->
          [
            model: Config.get(:review_model),
            model_url: Config.get(:review_model_url),
            backstop_ms: Config.get(:review_backstop_ms),
            backstop_kind: :review_call,
            role: :reviewer
          ]

        _ ->
          []
      end

    opts = role_opts ++ opts
    opts = opts ++ Keyword.get(st.opts, :model_opts, [])

    result =
      with_gate(st, fn ->
        remaining = budget_remaining!()
        timeout = min(remaining, opts[:backstop_ms] || Config.get(:backstop_model_ms))
        mod(st, :model, Model).chat(messages, Keyword.put(opts, :backstop_ms, timeout))
      end)

    # Preserve a complete late reply too; a deadline never erases work.
    case result do
      {:ok, reply} -> record(st, :reply, Map.put(reply, :role, role))
      _ -> :ok
    end

    tally(:model_calls, tally(:model_calls) + 1)

    case result do
      {:ok, reply} ->
        usage = Map.get(reply, :usage) || %{}
        tally(:prompt_tokens, tally(:prompt_tokens) + (usage[:prompt_tokens] || 0))
        tally(:completion_tokens, tally(:completion_tokens) + (usage[:completion_tokens] || 0))

      _ ->
        :ok
    end

    budget_remaining!()

    case result do
      {:ok, reply} ->
        {:ok, reply}

      {:error, reason} when role == :reviewer ->
        record(st, :error, %{stage: :reviewer, reason: reason})
        {:review_error, reason}

      {:error, :model_down} ->
        record(st, :error, %{stage: role, reason: :model_down})
        {:stop, report(st, :failed, "The code model is not running.")}

      {:error, :output_limit} ->
        record(st, :error, %{stage: role, reason: :output_limit})

        {:stop,
         report(
           st,
           :failed,
           "The #{role} exhausted its output budget before submitting an answer. Replan the budget before another attempt."
         )}

      {:error, {:http, status}} ->
        record(st, :error, %{stage: role, reason: {:http, status}})
        {:stop, report(st, :failed, "The code model answered HTTP #{status}.")}

      {:error, reason} ->
        record(st, :error, %{stage: role, reason: reason})

        {:retry, {:model, reason},
         "Your last reply was not usable (#{describe(reason)}). Answer more briefly and submit the changes #{submit_how(st)}."}
    end
  end

  defp with_gate(st, fun) do
    case Keyword.get(
           st.opts,
           :gate,
           {fn -> EmbedGate.hold(EmbedGate, budget_remaining!()) end, &EmbedGate.release/0}
         ) do
      false ->
        fun.()

      {hold, release} ->
        case hold.() do
          :ok ->
            :ok

          {:error, :timeout} ->
            {phase, _} = tally(:phase)
            throw({:budget_expired, phase})
        end

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
     "Your reply was cut off before it ended. Submit fewer, shorter edits #{submit_how(st)}."}
  end

  defp blocks(_st, %{edit_blocks: blocks}), do: {:ok, blocks}

  defp blocks(st, reply) do
    case Tools.text_edit_blocks(reply.content) do
      {:ok, edits} ->
        {:ok, edits}

      {:error, message} ->
        record(st, :edit, %{status: :unparsed, error: message})
        {:retry, :unparsed, message}

      :none ->
        legacy_blocks(st, reply)
    end
  end

  defp legacy_blocks(st, reply) do
    case Edits.parse(reply.content) do
      {:ok, []} ->
        record(st, :edit, %{status: :no_blocks})

        {:retry, :no_blocks,
         "Your reply had no edits. Submit the path/search/replace blocks #{submit_how(st)}."}

      {:ok, blocks} ->
        {:ok, blocks}

      {:error, message} ->
        record(st, :edit, %{status: :unparsed, error: message})
        {:retry, :unparsed, "Your blocks could not be read:\n\n#{message}"}
    end
  end

  defp apply_edits(st, blocks) do
    tally(:previous_edits, blocks)

    relocate = fn r ->
      record(st, :edit, %{status: :relocated, relocation: r})
      tally(:relocations, [r | tally(:relocations)])
    end

    case Edits.apply(st.ws.path, blocks,
           files: tracked(st.ws.path),
           shown: Map.get(st.task, :files, []),
           on_relocate: relocate
         ) do
      {:ok, paths} ->
        record(st, :edit, %{status: :applied, blocks: blocks, paths: paths})
        tally(:changed, paths)
        :ok

      {:error, failures} ->
        record(st, :edit, %{status: :missed, blocks: blocks, failures: failures})

        missing =
          for f <- failures,
              f.reason in [:no_such_file, :no_match] and f.closest == "",
              do: f.block.path

        if st.task.read_rounds == 0 and missing != [] do
          record(st, :error, %{stage: :edits, reason: :source_context_missing, paths: missing})

          {:stop,
           report(
             st,
             :failed,
             "source_context_missing: #{Enum.join(missing, ", ")}. " <>
               "Supply literal current SEARCH anchors or authorize read rounds on a fresh admission; no zero-read retry was run.",
             %{attempts: length(st.failures) + 1}
           )}
        else
          {:retry, :edits_missed, Edits.feedback(failures)}
        end
    end
  end

  defp prepare_artifacts(%{task: %{artifacts: nil}}), do: :ok

  defp prepare_artifacts(st) do
    case Artifacts.prepare(st.ws.path, st.task.artifacts, verification_opts(st)) do
      {:ok, evidence} ->
        record(st, :attempt, Map.put(evidence, :stage, :artifacts))
        tally(:artifacts, evidence)
        tally(:changed, Enum.uniq(tally(:changed) ++ evidence.paths))
        :ok

      {:error, %{reason: :preparation_failed} = evidence} ->
        record(st, :attempt, Map.put(evidence, :stage, :artifacts))
        {:retry, :preparation_failed, "Artifact preparation failed: #{evidence.output_tail}"}

      {:error, evidence} ->
        record(st, :error, Map.put(evidence, :stage, :artifacts))
        {:stop, report(st, :failed, "Artifact preparation refused: #{inspect(evidence.reason)}.")}
    end
  end

  defp tracked(path) do
    case System.cmd("git", ["ls-files", "-z"], cd: path, stderr_to_stdout: true) do
      {out, 0} -> String.split(out, "\0", trim: true)
      _ -> []
    end
  end

  defp compile_checkpoint(%{task: %{compilation: nil}}), do: :ok

  defp compile_checkpoint(st) do
    tree = Lifecycle.tree(st.ws, tally(:changed))
    result = mod(st, :check, Check).run(st.ws.path, st.task.compilation, verification_opts(st))

    record(
      st,
      :check,
      Map.merge(result, %{phase: :compilation, tree: tree, command: st.task.compilation})
    )

    budget_remaining!()

    cond do
      result.status != :pass ->
        {:retry, :compilation_failed,
         "Compilation failed; correct the code before a checkpoint can be committed.\n" <>
           result.output_tail}

      Lifecycle.tree(st.ws, tally(:changed)) != tree ->
        {:stop,
         report(
           st,
           :failed,
           "Compilation changed the candidate tree; no unchecked snapshot was committed."
         )}

      true ->
        with {:ok, message} <- commit_message(st.task.request) do
          opts =
            Keyword.put(Keyword.get(st.opts, :checkpoint_opts, []), :timeout, budget_remaining!())

          record(st, :attempt, %{
            stage: :compiled_checkpoint_pending,
            tree: tree,
            worktree: st.ws.path <> "-compiled"
          })

          changed = tally(:changed)
          previous = tally(:compiled)

          published =
            Backstop.guard(
              :compiled_checkpoint,
              st.id,
              {:ms, budget_remaining!()},
              fn -> %{tree: tree} end,
              fn ->
                CompiledCheckpoint.publish(
                  st.id,
                  st.ws,
                  tree,
                  changed,
                  message,
                  previous,
                  opts
                )
              end
            )

          case published do
            {:ok, {:ok, cp}} ->
              tally(:compiled, cp)
              record(st, :attempt, Map.merge(Map.drop(cp, [:ws]), %{stage: :compiled_checkpoint}))
              budget_remaining!()
              :ok

            error ->
              record(st, :error, %{stage: :compiled_checkpoint, reason: inspect(error)})

              {:stop,
               report(
                 st,
                 :failed,
                 "Compiled checkpoint could not be completed; source and checkpoint intent are retained.",
                 %{reason: :compiled_checkpoint_failed}
               )}
          end
        else
          {:error, reason} ->
            {:stop, report(st, :failed, "Compile checkpoint refused: #{describe(reason)}.")}
        end
    end
  end

  defp test_failure_report(_st, %{status: :pass}), do: :ok

  defp test_failure_report(st, result) do
    cp = tally(:compiled) || %{commit: nil, tree: result.tree, branch: st.ws.branch}
    key = {cp.commit || cp.tree, result.command}

    unless Map.has_key?(tally(:test_bugs), key) do
      opts = Keyword.get(st.opts, :checkpoint_opts, [])
      opts = Keyword.put(opts, :timeout, min(30_000, budget_remaining!()))

      opts =
        Keyword.put(
          opts,
          :source_request,
          st.task.request |> String.split("\n", parts: 2) |> hd()
        )

      case CompiledCheckpoint.report_failure(st.task.repo, st.id, cp, result, opts) do
        {:ok, ref} ->
          tally(:test_bugs, Map.put(tally(:test_bugs), key, ref))

          record(st, :attempt, %{
            stage: :test_failure_bug,
            ref: ref,
            commit: cp.commit,
            tree: cp.tree
          })

        error ->
          record(st, :error, %{
            stage: :test_failure_bug,
            reason: inspect(error),
            commit: cp.commit
          })

          throw({:lifecycle_error, {:test_failure_bug, error}})
      end
    end

    :ok
  end

  defp run_check(_st, nil), do: :ok

  defp run_check(st, command) do
    tree = Lifecycle.tree(st.ws, tally(:changed))

    result =
      mod(st, :check, Check).run(st.ws.path, command, verification_opts(st))

    result = Map.merge(result, %{command: command, tree: tree})
    record(st, :check, result)
    lifecycle(Lifecycle.record_check(st.id, result))
    tally(:check, result)
    test_failure_report(st, result)
    budget_remaining!()

    case result.status do
      :pass ->
        :ok

      status ->
        {:retry, {:check, status},
         "The check `#{command}` #{if status == :timeout, do: "timed out", else: "failed"}. " <>
           "The end of its output:\n\n#{result.output_tail}"}
    end
  end

  # The review, in a fresh context: the request, the design, the diff only.
  # Spark never reviews Spark; the reviewer is a different model on its
  # own router. An unclear, timed-out, unavailable or unusable review is
  # never fed back to the coder and never fails a tree that passed its
  # check.
  defp review(st) do
    if Config.get(:review_model) == Config.get(:code_model) do
      record(st, :review, %{verdict: :refused, reason: :same_model})
      {:awaiting_review, :same_model_review_refused}
    else
      diff = mod(st, :workspace, Workspace).diff(st.ws, tally(:changed))

      artifact_note =
        case tally(:artifacts) do
          nil ->
            ""

          evidence ->
            "\n\nTrusted artifact preparation (review generated/deleted outputs and modified build definitions):\n" <>
              Jason.encode!(
                Map.take(evidence, [
                  :command,
                  :paths,
                  :deleted_paths,
                  :definitions_changed,
                  :policy_hash
                ])
              )
        end

      messages = Prompts.reviewer(st.task, diff <> artifact_note, st.head.evidence)
      review_passes(st, messages, 1)
    end
  end

  # One review pass per Backstop, and three passes at most per case; a
  # retry never inherits or resets a larger budget. An error or timeout
  # consumes a pass like an unclear verdict, and the pass after the
  # third parks the case for the frontier.
  defp review_passes(st, messages, pass) when pass <= 3 do
    case converse(st, messages, nil, :reviewer) do
      {:ok, reply} ->
        case judged(reply) do
          :pass ->
            record(st, :review, %{verdict: :pass, pass: pass, text: reply.content})
            :ok

          {:fail, findings} ->
            record(st, :review, %{verdict: :fail, pass: pass, text: findings})
            {:retry, :review, "The review of your change found:\n\n#{findings}"}

          {:unclear, text} ->
            record(st, :review, %{verdict: :unclear, pass: pass, text: text})

            if pass < 3 do
              disambiguate(messages, reply)
              |> then(&review_passes(st, &1, pass + 1))
            else
              {:awaiting_review, :review_unclear}
            end
        end

      {:review_error, reason} ->
        record(st, :review, %{verdict: :unavailable, pass: pass, reason: reason})

        if pass < 3 do
          review_passes(st, messages, pass + 1)
        else
          {:awaiting_review, reason}
        end
    end
  end

  defp disambiguate(messages, reply) do
    messages ++
      [
        %{role: "assistant", content: reply.content},
        %{role: "user", content: "Answer with exactly PASS, or FAIL: and the findings."}
      ]
  end

  # a review cut off at the length limit may say PASS and mean nothing
  defp judged(%{finish_reason: "length", content: text}), do: {:unclear, text}
  defp judged(reply), do: Prompts.review_verdict(reply.content)

  # The review could not produce a verdict the machine may act on. The
  # checked tree is the work product: pin it to a durable ref before
  # anything else is released, keep the workspace and branch as evidence,
  # and close as awaiting_review. No reset, no coder call, no commit —
  # an unusable review is not a defect to fix.
  defp awaiting_review(st, reason) do
    ws = st.ws
    tree = Lifecycle.tree(ws, tally(:changed))
    ref = "refs/trailblazer/checkpoints/" <> st.id

    pinned =
      case git(ws.path, ["update-ref", ref, tree]) do
        {:ok, _} -> true
        {:error, _} -> false
      end

    record(st, :review, %{
      verdict: :awaiting_review,
      reason: reason,
      tree: tree,
      ref: ref,
      pinned: pinned
    })

    note =
      if reason == :verification_budget_exhausted do
        "The shared 15-minute verification budget expired. The tree at #{ref} is preserved; check status is #{inspect(tally(:check) && tally(:check).status)}. Frontier verification is required; no automatic coder retry."
      else
        "The reviewer could not produce a verdict (#{describe(reason)}). " <>
          "The checked tree is pinned at #{ref} (tree #{tree}); " <>
          "the worktree and branch are retained; no commit was made and " <>
          "the coder was not asked again. The frontier reviews; nothing is re-coded."
      end

    report(
      st,
      :awaiting_review,
      note,
      %{
        files: tally(:changed),
        tree: tree,
        ref: ref,
        reason: reason,
        pinned: pinned,
        attempts: length(st.failures) + 1
      }
    )
    |> Map.put(:awaiting_review, %{ref: ref, tree: tree, reason: reason, pinned: pinned})
  end

  defp git(dir, args) do
    case System.cmd("git", ["-c", "core.hooksPath=/dev/null" | args],
           cd: dir,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, String.trim(out)}
    end
  end

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
        evidence = tally(:check)
        current_tree = Lifecycle.tree(st.ws, tally(:changed))

        commit =
          if evidence.tree == current_tree do
            with {:ok, message} <- commit_message(st.task.request),
                 {:ok, _} <- Lifecycle.prepare_commit(st.id, current_tree, evidence),
                 do: workspace.commit(st.ws, message, tally(:changed))
          else
            {:error,
             "the candidate changed after its trusted check; use a check that does not rewrite tracked files"}
          end

        case commit do
          {:ok, sha} ->
            journal = lifecycle(Lifecycle.reconcile(st.id))

            if journal["candidate"] == sha do
              refs = Map.values(tally(:test_bugs)) |> Enum.uniq()

              if refs != [] do
                resolved =
                  CompiledCheckpoint.resolve(
                    st.task.repo,
                    refs,
                    sha,
                    Keyword.get(st.opts, :checkpoint_opts, [])
                  )

                record(st, :attempt, %{stage: :test_bugs_resolved, results: resolved})
              end

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

  # A primary admitted with the case is the trusted policy that hands its
  # outcome to the coordinator: a fixed candidate is integrated, anything else
  # is archived, and both end with the managed checkout and branch removed.
  # Without one the candidate branch (and an unfinished worktree) stays for
  # the caller, as before. A blocked coordinator keeps the candidate and says
  # why; the public status stays as the Loop decided it.
  defp coordinate(id, report, opts) do
    coordinator = Keyword.get(opts, :coordinator, Trailblazer.Loop.Coordinator)

    case Lifecycle.get(id) do
      %{"primary" => primary} when is_binary(primary) ->
        result =
          cond do
            report.status == :fixed ->
              checks = Keyword.get(opts, :check_opts, [])
              checks = Keyword.put(checks, :deadline_at, report.verification_deadline_at)
              coordinator.accept(id, check_opts: checks)

            report.status == :awaiting_review or
                report[:reason] in [
                  :edit_repair_exhausted,
                  :source_context_missing,
                  :decomposition_required,
                  :compiled_checkpoint_failed
                ] ->
              {:ok, %{"stage" => "retained"}}

            true ->
              coordinator.retire(id, [])
          end

        coordinated(report, result)

      _ ->
        report
    end
  rescue
    e -> coordinated(report, {:error, {:coordinator_crashed, Exception.message(e)}})
  end

  defp coordinated(report, {:ok, %{"stage" => "cleanup_complete"} = r}) do
    %{
      report
      | worktree: nil,
        summary:
          report.summary <>
            " Integrated into #{r["primary"]} at #{r["result"]}; candidate branch and checkout removed, evidence archived at #{r["archive"]["path"]}."
    }
    |> Map.put(:integration, %{
      primary: r["primary"],
      result: r["result"],
      archive: r["archive"]["path"]
    })
  end

  defp coordinated(report, {:ok, %{"stage" => "retained"}}) do
    %{
      report
      | summary:
          report.summary <>
            " Not integrated; workspace, branch and checked tree retained for frontier review."
    }
  end

  defp coordinated(report, {:ok, %{"stage" => "discarded"} = r}) do
    %{
      report
      | worktree: nil,
        summary:
          report.summary <>
            " Not integrated; evidence archived at #{r["archive"]["path"]} and the checkout and branch removed."
    }
    |> Map.put(:archive, r["archive"]["path"])
  end

  defp coordinated(report, {:error, reason}) do
    %{
      report
      | summary:
          report.summary <>
            " Coordinator blocked: #{inspect(reason)}; candidate and evidence retained."
    }
  end

  defp coordinated(report, _), do: report

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
    attempts = length(st.failures)

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
        diagnosis: "All #{attempts} attempts failed: #{diagnosis}."
      })

    record(st, :dossier, %{text: dossier})

    report(
      st,
      :failed,
      "#{attempts} attempts failed: #{diagnosis}. Decompose this card into smaller tasks; preserved attempt checkpoints and the dossier show what was tried.",
      %{
        attempts: attempts,
        dossier: dossier,
        reason: :decomposition_required,
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
      case: st.id,
      verification_deadline_at: System.os_time(:millisecond) + verification_remaining(st),
      compiled: compiled_report(),
      test_bugs: Map.values(tally(:test_bugs)) |> Enum.uniq()
    }

    report = Map.merge(report, Map.take(extra, [:reason]))
    if extra[:dossier], do: Map.put(report, :dossier, extra[:dossier]), else: report
  end

  defp compiled_report do
    case tally(:compiled) do
      nil -> nil
      cp -> cp |> Map.drop([:ws, :source, :case]) |> Map.put(:base, cp.ws.base)
    end
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

  defp submit_how(%{task: %{edit_mode: :text}}), do: "as plain-text SEARCH/REPLACE blocks"
  defp submit_how(_st), do: "with submit_edits"

  defp tally(key), do: Process.get(@tally, %{}) |> Map.get(key, 0)
  defp tally(key, value), do: Process.put(@tally, Map.put(Process.get(@tally, %{}), key, value))

  defp mod(st, key, default), do: Keyword.get(st.opts, key, default)
  defp query_opts(st), do: Keyword.get(st.opts, :query_opts, [])
  defp now, do: System.monotonic_time(:millisecond)

  defp normalize(task) do
    get = fn key -> task[key] || task[to_string(key)] end
    read_rounds = Map.get(task, :read_rounds, Map.get(task, "read_rounds", @tool_rounds))

    reasoning_budget =
      Map.get(task, :reasoning_budget_tokens, Map.get(task, "reasoning_budget_tokens"))

    replay = Map.get(task, :replay_reply_from, Map.get(task, "replay_reply_from"))

    unless is_nil(replay) or
             (is_binary(replay) and
                Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9:._-]{0,127}\z/, replay)),
           do: raise(ArgumentError, "invalid replay_reply_from")

    unless is_integer(read_rounds) and read_rounds in 0..@tool_rounds,
      do: raise(ArgumentError, "read_rounds must be an integer from 0 to #{@tool_rounds}")

    unless is_nil(reasoning_budget) or Model.valid_reasoning_budget?(reasoning_budget),
      do: raise(ArgumentError, "invalid reasoning_budget_tokens")

    edit_mode =
      case Map.get(task, :edit_mode, Map.get(task, "edit_mode")) do
        nil -> Config.get(:code_edit_mode)
        mode when mode in [:tool, "tool"] -> :tool
        mode when mode in [:text, "text"] -> :text
        _ -> raise(ArgumentError, "edit_mode must be tool or text")
      end

    %{
      repo: get.(:repo),
      request: get.(:request),
      files: get.(:files) || [],
      design: get.(:design),
      check: get.(:check),
      primary: get.(:primary),
      # Atom-only internal metadata; JSON request fields cannot grant commands.
      artifacts: Map.get(task, :artifacts),
      compilation: Map.get(task, :compilation),
      read_rounds: read_rounds,
      reasoning_budget_tokens: reasoning_budget,
      edit_mode: edit_mode,
      replay_reply_from: replay,
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

  # The request's first line is the whole commit message: the operator's hooks (run
  # by Workspace.commit) require a bug:<id> in our repositories and cap the message at
  # 255 characters, details living in the bug. Never truncate: a cut could drop the
  # reference, so an over-long line leaves the work uncommitted.
  @commit_limit 255
  defp commit_message(request) do
    line = request |> String.trim() |> String.split("\n", parts: 2) |> hd() |> String.trim()

    if String.length(line) > @commit_limit,
      do: {:error, "the request's first line is over #{@commit_limit} characters"},
      else: {:ok, line}
  end

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
