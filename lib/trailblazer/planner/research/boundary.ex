defmodule Trailblazer.Planner.Research.Boundary do
  @moduledoc "The research route's runner and VORTEX transport boundaries: planner CLI calls and transport ops."

  alias Trailblazer.Planner.Board

  # The application's own authenticated VORTEX endpoint carries the research
  # route's ops; nothing here needs a peer credential. With no vortex at all
  # the announce holds on :no_transport instead of crashing.
  @doc false
  def endpoint_transport do
    # Settings.load/1 yields a keyword list (tests may inject a map).
    vortex = Trailblazer.Config.get(:vortex)
    endpoint = if is_list(vortex) or is_map(vortex), do: vortex[:endpoint]
    if is_binary(endpoint), do: &Trailblazer.Vortex.Transport.call(endpoint, &1, &2)
  end

  @doc false
  def perform(nil, config, args), do: run_status(Board.run(config, args))

  def perform(fun, _config, args) when is_function(fun, 1),
    do: run_status(fun.(args))

  defp run_status(%{status: :pass} = result), do: {:ok, result[:output_tail] || ""}
  defp run_status(%{output_tail: tail}), do: {:error, String.slice(tail || "unknown", 0, 300)}
  defp run_status(_), do: {:error, "the runner answered without a status"}

  @doc false
  def transport(nil, _op, _args), do: {:error, :no_transport, "no transport configured"}

  def transport(fun, op, args) do
    case fun.(op, args) do
      {:error, reason} -> {:error, op_atom(op), reason}
      result -> {:ok, result}
    end
  end

  defp op_atom("create"), do: :create
  defp op_atom("post"), do: :post
  defp op_atom("subscribe"), do: :subscribe
  defp op_atom("send"), do: :send
  defp op_atom(other), do: other
end
