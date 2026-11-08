defmodule Trailblazer.Store.ResolutionAccess do
  @moduledoc "The resolver's state as the store serves it: each read or write runs in its own transaction, and no closure outlives its connection."

  alias Trailblazer.Store.{Resolution, Sql}
  import Trailblazer.Store, only: [read: 1, run: 1]
  import Trailblazer.Store.Sql
  import Trailblazer.Store.Reads, only: [graph_snapshot: 2]

  @node_select Sql.node_select()
  @ref_select Sql.ref_select()

  # Resolution metadata is stored in SQLite, never in a long-lived closure.
  defp resolution_read(fun) do
    case read(fn conn ->
           if Resolution.installed?(conn), do: {:ready, fun.(conn)}, else: :needs_schema
         end) do
      {:ready, value} ->
        value

      :needs_schema ->
        run(&Resolution.ensure/1)
        read(fun)
    end
  end

  def resolution_state(repo), do: resolution_read(&Resolution.state(&1, repo))
  def resolution_current?(repo), do: resolution_read(&Resolution.current?(&1, repo))
  def resolution_readers(repo, tokens), do: resolution_read(&Resolution.readers(&1, repo, tokens))
  def resolution_dependencies(repo), do: resolution_read(&Resolution.dependencies(&1, repo))

  def replace_resolved_sources(repo, revision, batch),
    do: run(&Resolution.replace(&1, repo, revision, batch))

  @doc false
  def resolution_file(conn, repo, path) do
    %{
      nodes:
        node_rows(
          conn,
          :resolution_nodes,
          @node_select <> " WHERE repo_id=? AND path=? ORDER BY id",
          [repo, path]
        ),
      refs:
        rows(
          conn,
          :resolution_refs,
          @ref_select <> " WHERE r.repo_id=? AND r.path=? ORDER BY r.id",
          [repo, path]
        )
    }
  end

  @doc false
  def resolution_selected(repo_id, resolver) do
    resolution_read(fn conn ->
      case Resolution.selection(conn, repo_id) do
        {:fallback, _} = fallback ->
          fallback

        plan ->
          resolver.(plan, fn token, limit -> Resolution.lookup(conn, repo_id, token, limit) end)
      end
    end)
  end

  def resolution_snapshot(repo_id) do
    resolution_read(fn conn ->
      state = Resolution.header(conn, repo_id)

      graph_snapshot(conn, repo_id)
      |> Map.merge(%{
        revision: state.revision,
        resolution: state,
        sources: Resolution.sources(conn, repo_id)
      })
    end)
  end
end
