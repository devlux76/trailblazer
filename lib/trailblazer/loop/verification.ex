defmodule Trailblazer.Loop.Verification do
  @moduledoc "Verification of one attempt: artifact preparation, the compilation checkpoint and the check."

  alias Trailblazer.{Backstop, Config}
  alias Trailblazer.Loop.{Artifacts, Check, CompiledCheckpoint, Finish, Lifecycle, Outcome}

  import Trailblazer.Loop.Ledger,
    only: [tally: 1, tally: 2, mod: 3, record: 3, budget_remaining!: 0, describe: 1, lifecycle: 1]

  defp verification_opts(st) do
    remaining = budget_remaining!()
    opts = Keyword.get(st.opts, :check_opts, [])

    opts
    |> Keyword.put(:timeout, min(remaining, opts[:timeout] || Config.get(:backstop_check_ms)))
    |> Keyword.put(:deadline_at, System.os_time(:millisecond) + remaining)
  end

  @doc false
  def prepare_artifacts(%{task: %{artifacts: nil}}), do: :ok

  def prepare_artifacts(st) do
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

        {:stop,
         Outcome.report(st, :failed, "Artifact preparation refused: #{inspect(evidence.reason)}.")}
    end
  end

  @doc false
  def compile_checkpoint(%{task: %{compilation: nil}}), do: :ok

  def compile_checkpoint(st) do
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
         Outcome.report(
           st,
           :failed,
           "Compilation changed the candidate tree; no unchecked snapshot was committed."
         )}

      true ->
        with {:ok, message} <- Finish.commit_message(st.task.request) do
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
               Outcome.report(
                 st,
                 :failed,
                 "Compiled checkpoint could not be completed; source and checkpoint intent are retained.",
                 %{reason: :compiled_checkpoint_failed}
               )}
          end
        else
          {:error, reason} ->
            {:stop,
             Outcome.report(st, :failed, "Compile checkpoint refused: #{describe(reason)}.")}
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

  @doc false
  def run_check(_st, nil), do: :ok

  def run_check(st, command) do
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
end
