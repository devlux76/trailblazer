defmodule Trailblazer.Planner.PermissionNotifier do
  @moduledoc """
  One locally configured active-notification attempt. The permission coordinator
  must durably claim its ordinal BEFORE calling this function. This primitive
  does not retry, persist decisions, or equate queued mail with an idle wake.
  Only request identifiers/digests enter the fixed message, never build output.
  """
  alias Trailblazer.Loop.Check
  @keys ~w(executable args cwd env timeout_ms)

  def validate(route) when is_map(route) do
    if Enum.all?(Map.keys(route), &(&1 in @keys)) and
         absolute?(route["executable"]) and absolute?(route["cwd"]) and
         is_list(route["args"]) and length(route["args"]) <= 64 and
         Enum.all?(route["args"], &text?/1) and valid_env?(Map.get(route, "env", %{})) and
         is_integer(Map.get(route, "timeout_ms", 60_000)) and
         Map.get(route, "timeout_ms", 60_000) in 1..300_000,
       do: :ok,
       else: {:error, :invalid_notifier}
  end

  def validate(_), do: {:error, :invalid_notifier}

  def notify(route, request, ordinal) do
    with :ok <- validate(route),
         true <- valid_request?(request) and ordinal in [0, 1] do
      message =
        "From Trailblazer (permission request, not the operator): " <>
          "request=#{request["id"]} binding=#{request["binding"]} " <>
          "evidence=#{request["evidence_sha256"]} notice=#{ordinal}. " <>
          "Retrieve bound evidence with trailblazer permission show #{request["id"]}; " <>
          "decide through your configured peer. This notice is not a grant."

      result =
        Check.run_argv(route["cwd"], route["executable"], route["args"] ++ [message],
          env: Map.get(route, "env", %{}),
          timeout: Map.get(route, "timeout_ms", 60_000)
        )

      {:ok, delivery(result)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_notification}
    end
  end

  defp delivery(result) do
    base = %{delivery: :unknown, exit: result.exit, ms: result.ms}

    cond do
      result.status == :timeout ->
        base

      result.status != :pass ->
        %{base | delivery: :failure}

      true ->
        case Jason.decode(String.trim(result.output_tail)) do
          {:ok, %{"delivery" => status} = reply} ->
            valid_turn? =
              is_binary(reply["turn_id"]) and
                Regex.match?(~r/\A[A-Za-z0-9_-]{1,100}\z/, reply["turn_id"])

            level =
              case status do
                value when value in ["started", "steered"] ->
                  if valid_turn?, do: :host_admitted, else: :unknown

                "queued" ->
                  :queued

                _ ->
                  :unknown
              end

            base = %{base | delivery: level}

            if valid_turn?,
              do: Map.put(base, :turn_id, reply["turn_id"]),
              else: base

          _ ->
            base
        end
    end
  end

  defp valid_request?(r) when is_map(r) do
    is_binary(r["id"]) and Regex.match?(~r/\Aperm-[0-9a-f]{32}\z/, r["id"]) and
      Enum.all?(~w(binding evidence_sha256), fn key ->
        is_binary(r[key]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, r[key])
      end)
  end

  defp valid_request?(_), do: false
  defp absolute?(v), do: text?(v) and Path.type(v) == :absolute

  defp text?(v),
    do:
      is_binary(v) and byte_size(v) <= 4096 and String.valid?(v) and
        not String.contains?(v, <<0>>)

  defp valid_env?(env) when is_map(env) and map_size(env) <= 32 do
    Enum.all?(env, fn {k, v} ->
      is_binary(k) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]{0,99}\z/, k) and text?(v)
    end)
  end

  defp valid_env?(_), do: false
end
