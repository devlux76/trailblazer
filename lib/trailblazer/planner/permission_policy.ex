defmodule Trailblazer.Planner.PermissionPolicy do
  @moduledoc "Trusted P1 frontier policy; an absent block leaves old behaviour unchanged."
  alias Trailblazer.Planner.PermissionNotifier

  def parse(nil, _peers), do: {:ok, nil}

  def parse(raw, peers) when is_map(raw) do
    timeout = Map.get(raw, "timeout_ms", 14_400_000)

    with true <- Enum.all?(Map.keys(raw), &(&1 in ~w(deciders timeout_ms))),
         true <- is_integer(timeout) and timeout > 0,
         deciders when is_map(deciders) and map_size(deciders) > 0 <- raw["deciders"],
         {:ok, parsed} <- deciders(deciders, peers),
         ids = Enum.map(parsed, fn {_, d} -> d.peer end),
         true <- length(Enum.uniq(ids)) == length(ids) do
      {:ok, %{timeout_ms: timeout, deciders: parsed}}
    else
      _ -> {:error, :invalid_permissions}
    end
  end

  def parse(_, _), do: {:error, :invalid_permissions}

  defp deciders(raw, peers) do
    Enum.reduce_while(raw, {:ok, %{}}, fn {name, d}, {:ok, acc} ->
      with true <- is_binary(name) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,31}\z/, name),
           true <- is_map(d) and Enum.sort(Map.keys(d)) == ~w(endpoint host notifier peer),
           true <- is_binary(d["peer"]) and d["peer"] != "",
           %{role: :frontier, room: room} <- peers[d["peer"]],
           true <- d["host"] in ["codex", "claude"],
           true <-
             is_binary(d["endpoint"]) and Path.type(d["endpoint"]) == :absolute and
               not String.contains?(d["endpoint"], <<0>>),
           :ok <- PermissionNotifier.validate(d["notifier"]),
           true <- pinned_route?(d["host"], d["notifier"]) do
        value = %{
          peer: d["peer"],
          room: room,
          host: d["host"],
          endpoint: d["endpoint"],
          notifier: d["notifier"]
        }

        {:cont, {:ok, Map.put(acc, name, value)}}
      else
        _ -> {:halt, {:error, :invalid_permissions}}
      end
    end)
  end

  defp pinned_route?("codex", notifier) do
    env = Map.get(notifier, "env", %{})

    env["PING_FROM"] == "Trailblazer" and is_binary(env["CODEX_THREAD"]) and
      Regex.match?(
        ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/,
        env["CODEX_THREAD"]
      )
  end

  defp pinned_route?("claude", _), do: true
end
