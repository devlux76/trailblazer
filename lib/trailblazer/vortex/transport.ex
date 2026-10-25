defmodule Trailblazer.Vortex.Transport do
  @moduledoc "The application's own authenticated VORTEX endpoint; no peer credentials."
  alias Trailblazer.{Backstop, Config}

  def call(endpoint_file, operation, arguments, expected_peer \\ nil)

  # The attach line streams and has no deadline, so it bypasses the backstop.
  # Routed here too so a bridge whose transport closure predates attach
  # (captured at init, kept across a hot load) still opens a line.
  def call(endpoint_file, "attach", %{"notify" => notify}, expected_peer),
    do: attach(endpoint_file, notify, expected_peer)

  def call(endpoint_file, operation, arguments, expected_peer) do
    result =
      Backstop.guard(
        :vortex,
        operation,
        {:ms, Config.get(:backstop_store_ms)},
        fn -> %{} end,
        fn ->
          with {:ok, bytes} <- File.read(endpoint_file),
               {:ok, %{"url" => url, "token" => token}} <- Jason.decode(bytes),
               %{scheme: "http", host: "127.0.0.1", port: port} when is_integer(port) <-
                 URI.parse(url),
               :ok <- identity(url, token, expected_peer),
               {:ok, %{status: 200, body: body}} <-
                 Req.post(url <> "/" <> operation,
                   json: arguments,
                   auth: {:bearer, token},
                   retry: false,
                   receive_timeout: :infinity,
                   connect_options: [timeout: :infinity]
                 ) do
            {:ok, body}
          else
            _ -> {:error, :transport_unavailable}
          end
        end
      )

    case result do
      {:ok, value} -> value
      _ -> {:error, :transport_unavailable}
    end
  rescue
    _ -> {:error, :transport_unavailable}
  end

  @doc """
  Holds a VORTEX attach line (presence design, vortex
  docs/2026-10-22-presence-design.md) until the service closes it. Each
  notice line with an unread count is sent to `notify` as
  `{:vortex_notice, unread}`. No timeout and no backstop: an open line is
  presence, and the line closing is the detach.
  """
  def attach(endpoint_file, notify, expected_peer \\ nil) do
    with {:ok, bytes} <- File.read(endpoint_file),
         {:ok, %{"url" => url, "token" => token}} <- Jason.decode(bytes),
         %{scheme: "http", host: "127.0.0.1", port: port} when is_integer(port) <- URI.parse(url),
         :ok <- identity(url, token, expected_peer),
         {:ok, %{status: 200}} <-
           Req.post(url <> "/attach",
             json: %{},
             auth: {:bearer, token},
             retry: false,
             receive_timeout: :infinity,
             connect_options: [timeout: :infinity],
             into: fn {:data, data}, acc ->
               notices(data, notify)
               {:cont, acc}
             end
           ) do
      {:ok, :closed}
    else
      _ -> {:error, :transport_unavailable}
    end
  rescue
    _ -> {:error, :transport_unavailable}
  end

  # NDJSON may split a line across chunks; the partial tail waits in the
  # line process's dictionary for the next chunk.
  defp notices(data, notify) do
    [tail | lines] =
      ((Process.get(:vortex_line, "") <> data) |> String.split("\n")) |> Enum.reverse()

    Process.put(:vortex_line, tail)

    for line <- Enum.reverse(lines), line != "" do
      case Jason.decode(line) do
        {:ok, %{"unread" => unread}} when is_integer(unread) ->
          send(notify, {:vortex_notice, unread})

        _ ->
          :ok
      end
    end
  end

  defp identity(_, _, nil), do: :ok

  defp identity(url, token, peer) do
    case Req.post(url <> "/info",
           json: %{},
           auth: {:bearer, token},
           retry: false,
           receive_timeout: :infinity,
           connect_options: [timeout: :infinity]
         ) do
      {:ok, %{status: 200, body: %{"peerId" => ^peer}}} -> :ok
      _ -> {:error, :wrong_owner}
    end
  end
end
