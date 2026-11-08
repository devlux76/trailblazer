defmodule Trailblazer.Vortex.Store.Returns do
  @moduledoc "The verdict on a frontier's returned fix (bug:a3339f5); see `Trailblazer.Vortex.Store`."
  alias Trailblazer.CaseStore
  alias Trailblazer.Vortex.Store

  @doc """
  Records a returned fix's verdict (`verified`, `rejected` or `failed`) and
  reports it to the primary. Only a return in `waiting_verification` moves; the
  state becomes `return_<outcome>`, which no later return can reopen. The
  summary travels in the report's outbox row, so it survives a restart.
  """
  def return_outcome(id, outcome, summary) when outcome in ~w(verified rejected failed) do
    request = Store.get(id)

    if request && request.returned_fix do
      payload = %{
        "case" => id,
        "returned_fix" => outcome,
        "commit" => request.returned_fix["commit"],
        "summary" => String.slice(summary, 0, 1200)
      }

      CaseStore.transaction(fn conn ->
        case query(
               conn,
               :vortex_return_outcome_target,
               "SELECT state FROM vortex_request WHERE case_id = ?",
               [id]
             ) do
          [["waiting_verification"]] ->
            query(
              conn,
              :vortex_return_outcome,
              "UPDATE vortex_request SET state = ? WHERE case_id = ?",
              ["return_" <> outcome, id]
            )

            Store.put(
              conn,
              id,
              request.peer,
              request.room,
              "report",
              request.request_id,
              payload,
              true,
              "returned-fix"
            )

            :ok

          _ ->
            {:error, :not_waiting}
        end
      end)
    else
      {:error, :not_waiting}
    end
  end

  defp query(conn, name, sql, params) do
    {_, %Exqlite.Result{rows: rows}} =
      Exqlite.prepare_execute!(conn, name, sql, params, timeout: :infinity)

    rows || []
  end
end
