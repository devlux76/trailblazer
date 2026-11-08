defmodule Trailblazer.Vortex.Bridge.Resources do
  @moduledoc """
  Resource ownership for the bridge: acquiring a grant for a case, releasing it, and
  backing off a release the resource could not confirm.
  """

  alias Trailblazer.Backstop
  alias Trailblazer.Vortex.Bridge
  alias Trailblazer.Vortex.Store

  # Unconfirmed release backoff: 5 s doubling to 5 min (the same bounds as Bridge).
  @release_retry_ms 5_000
  @release_retry_max_ms 300_000

  @doc false
  def acquire(id, state) do
    {acquire, _} = state.resource
    # Persist intent before an asynchronous grant can outlive this bridge.
    lease = id <> ":" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    :ok = Store.reserve(id, lease)

    Bridge.job(%{state | resource_busy: true}, {:acquire_resource, id, lease}, fn ->
      acquire.(lease)
    end)
  end

  # Backoff: release_retry_ms doubling per failure up to release_retry_max_ms,
  # for as long as it takes.
  @doc false
  def arm_release_retry(state, id, lease, result) do
    failures = max(Map.get(state, :release_failures, 1), 1)
    base = Map.get(state, :release_retry_ms, @release_retry_ms)
    cap = Map.get(state, :release_retry_max_ms, @release_retry_max_ms)
    delay = min(base * Integer.pow(2, min(failures - 1, 20)), cap)

    case Map.get(state, :release_retry) do
      {old, _, _} -> Backstop.disarm(old)
      _ -> :ok
    end

    ref =
      Backstop.arm(:resource_release_blocked, id, {:ms, delay}, fn ->
        %{lease: lease, failures: failures, result: inspect(result, limit: 10)}
      end)

    Map.put(state, :release_retry, {ref, id, lease})
  end

  @doc false
  def release_resource(state, id, lease) do
    {_, release} = state.resource

    Bridge.job(%{state | resource_busy: true}, {:release_resource, id, lease}, fn ->
      release.(lease)
    end)
  end
end
