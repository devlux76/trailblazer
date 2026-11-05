defmodule Trailblazer.Config do
  @moduledoc """
  Trailblazer's settings: where its state lives, where the embedder and the
  vector store are, and the budgets it works to.

  A setting is taken from the application environment first, then from the
  system environment, then from the default below. `TRAILBLAZER_STATE_DIR` names
  the directory that holds `trailblazer.db` and `endpoint.json`;
  `TRAILBLAZER_EMBED_URLS` (comma-separated) is the pool of embedders that
  documents are spread over, the first of which also answers queries.
  """

  @doc """
  The value of `key`.

  ## Examples

      iex> Trailblazer.Config.get(:api_port)
      7900

  """
  @spec get(atom()) :: term()
  def get(key) do
    Application.get_env(:trailblazer, key) || from_system_env(key) || default(key)
  end

  @doc "Load optional authority settings once at application boot; reads never reload files."
  def load_runtime_settings do
    settings = Map.new([:vortex, :planner], &{&1, read_setting(&1)})
    Application.put_env(:trailblazer, :runtime_settings, settings)
    :ok
  end

  @doc "Availability of an optional authority subsystem, without exposing configuration bytes."
  def runtime_status(key) when key in [:vortex, :planner] do
    case setting(key) do
      {:ok, _} -> %{state: :ok, reason: nil}
      :not_configured -> %{state: :not_configured, reason: nil}
      {:error, _} -> %{state: :unavailable, reason: "invalid local #{key} configuration"}
    end
  end

  defp setting(key) do
    case Application.get_env(:trailblazer, key) do
      nil ->
        case Application.get_env(:trailblazer, :runtime_settings) do
          nil -> read_setting(key)
          settings -> Map.fetch!(settings, key)
        end

      value ->
        {:ok, value}
    end
  end

  defp read_setting(key) do
    variable =
      if key == :vortex, do: "TRAILBLAZER_VORTEX_CONFIG", else: "TRAILBLAZER_PLANNER_CONFIG"

    cond do
      value = Application.get_env(:trailblazer, key) -> {:ok, value}
      path = System.get_env(variable) -> load_setting(key, path)
      true -> :not_configured
    end
  end

  defp load_setting(:vortex, path), do: Trailblazer.Vortex.Settings.load(path)

  defp load_setting(:planner, path) do
    {:ok, Trailblazer.Planner.Board.load_config!(path)}
  rescue
    _ -> {:error, :invalid_config}
  end

  defp configured(key) do
    case setting(key) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  @doc """
  How many characters of a definition's document are embedded for the
  repository at `repo`: `:compact_limit` under any of `:compact_roots`
  (`TRAILBLAZER_COMPACT_ROOTS`, comma-separated), else `:doc_limit`.
  """
  @spec doc_limit(Path.t()) :: pos_integer()
  def doc_limit(repo) do
    if Enum.any?(get(:compact_roots), &under?(repo, &1)),
      do: get(:compact_limit),
      else: get(:doc_limit)
  end

  defp under?(path, root) do
    root = String.trim_trailing(root, "/")
    path == root or String.starts_with?(path, root <> "/")
  end

  defp from_system_env(:state_dir), do: System.get_env("TRAILBLAZER_STATE_DIR")

  defp from_system_env(:code_edit_mode) do
    case System.get_env("TRAILBLAZER_CODE_EDIT_MODE") do
      "text" -> :text
      "tool" -> :tool
      _ -> nil
    end
  end

  defp from_system_env(:vortex), do: configured(:vortex)
  defp from_system_env(:planner), do: configured(:planner)

  defp from_system_env(:compact_roots) do
    case System.get_env("TRAILBLAZER_COMPACT_ROOTS") do
      nil -> nil
      roots -> roots |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp from_system_env(:compact_limit) do
    case System.get_env("TRAILBLAZER_COMPACT_LIMIT") do
      nil -> nil
      limit -> String.to_integer(String.trim(limit))
    end
  end

  defp from_system_env(:embed_urls) do
    case System.get_env("TRAILBLAZER_EMBED_URLS") do
      nil -> nil
      urls -> urls |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp from_system_env(_key), do: nil

  defp default(:vortex), do: nil
  # The planner brain is off until a config file admits repositories to it.
  defp default(:planner), do: nil

  defp default(:state_dir), do: Path.join(System.user_home!(), ".local/share/trailblazer")
  defp default(:embed_url), do: "http://127.0.0.1:8091/v1/embeddings"
  defp default(:embed_urls), do: [get(:embed_url)]
  # Reference trees (vendored copies of other projects) can be embedded from
  # a shorter document: header plus the start of the source (2026-10-22: a
  # 2,400-character document is ~675 tokens, ~1 doc/s on the Polaris).
  defp default(:compact_roots), do: []
  defp default(:compact_limit), do: 600
  defp default(:doc_limit), do: 2_400
  defp default(:embed_model), do: "embeddinggemma-2"
  defp default(:qdrant_url), do: "http://127.0.0.1:6333"
  defp default(:api_port), do: 7900
  defp default(:trail_tokens), do: 4000

  # Production investigations use the durable app bridge. Transport writes
  # alone never mark receipt, and no model is needed to queue a request.
  defp default(:investigate_transport),
    do: if(get(:vortex), do: :vortex_bridge, else: :unavailable)

  defp default(:code_model), do: "spark-x2.6-4b:q8-dspark"
  defp default(:code_model_url), do: "http://127.0.0.1:8096/v1"
  # The planner brain's model (Bolt + DFlash, small strict-JSON choices) on its
  # own server on the iGPU (Vulkan), so it never takes CPU from the coding model.
  defp default(:planner_model), do: "nemotron-3.5-bolt-e4b:q4"
  defp default(:planner_model_url), do: "http://127.0.0.1:8098/v1"
  # Only a planner sharing the coding model's router needs the CPU lease (whose
  # verified unload is of planner_model).
  defp default(:planner_lease), do: get(:planner_model_url) == get(:code_model_url)

  # The reviewer works on its own server on the iGPU; the coding model must never review its own work (operator rule).
  # Served by the planner brain's iGPU server when it is up; when it is down the review escalates to the frontier, it does not
  # fail the checked case.
  defp default(:review_model), do: "nemotron-3.5-bolt-e4b:q4"
  defp default(:review_model_url), do: "http://127.0.0.1:8098/v1"
  # A review call is additionally clamped to the card's shared verification allowance.
  defp default(:review_backstop_ms), do: 900_000
  defp default(:code_model_max_tokens), do: 16_384
  # How the coder submits edits: :tool (native submit_edits) or :text
  # (SEARCH/REPLACE blocks in plain text; small models handle it better).
  defp default(:code_edit_mode), do: :tool
  # Optional %{temperature, top_p, top_k, thinking} per role; nil keeps the
  # Model defaults (1.0 / 0.95 / 0, thinking on).
  defp default(:code_model_sampling), do: nil
  defp default(:review_model_sampling), do: nil
  # Backstops (design §13.2): set from measurements with a wide margin, so
  # firing means something is wrong. A model call can read an 11-minute
  # prompt and generate 16k tokens at ~3 tokens/s (~90 minutes).
  defp default(:backstop_model_ms), do: 7_200_000
  defp default(:backstop_check_ms), do: 1_800_000
  defp default(:backstop_store_ms), do: 600_000
  defp default(:backstop_watcher_ms), do: 120_000
  # The parse pool (design §13.4): one tree-sitter Port per worker, and the
  # model owns most of the six threads, so there are two. A parse of a file
  # that is not pathological takes well under a second; five minutes means
  # something is wrong, not that the machine is busy.
  defp default(:parse_workers), do: 2
  defp default(:backstop_parse_ms), do: 300_000
  # The embedder down for half an hour with work waiting is worth a look.
  defp default(:backstop_embed_ms), do: 1_800_000
  # EmbedHealth's probe gap doubles from 1 s up to this, only while work waits.
  defp default(:embed_retry_cap_ms), do: 60_000
  defp default(:embed_probe), do: :http
  # HTTP to the embedder and Qdrant has no client timeout; these guard it.
  # Sixteen definitions on a loaded CPU took up to ~2 minutes (E19).
  defp default(:backstop_embed_batch_ms), do: 900_000
  defp default(:backstop_search_ms), do: 300_000
  defp default(:backstop_embed_probe_ms), do: 300_000

  defp default(:check_path) do
    home = System.user_home!()

    Enum.join(
      [
        Path.join(home, ".local/share/mise/shims"),
        Path.join(home, ".bun/bin"),
        Path.join(home, ".local/bin"),
        Path.join(home, ".cargo/bin"),
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/snap/bin"
      ],
      ":"
    )
  end

  defp default(key) do
    raise ArgumentError, "unknown Trailblazer setting: #{inspect(key)}"
  end
end
