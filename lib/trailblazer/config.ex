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

  defp from_system_env(:vortex) do
    if path = System.get_env("TRAILBLAZER_VORTEX_CONFIG"),
      do: Trailblazer.Vortex.Settings.load!(path)
  end

  defp from_system_env(:planner) do
    if path = System.get_env("TRAILBLAZER_PLANNER_CONFIG"),
      do: Trailblazer.Planner.Board.load_config!(path)
  end

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

  # a coding task that names its files gets them in full; its trail is for
  # what those files touch, and prompt tokens cost ~90 s per 1000 on the CPU
  defp default(:loop_trail_tokens), do: 1500
  defp default(:code_model), do: "qwen3.6-35b-a3b:mtp-q4"
  defp default(:code_model_url), do: "http://127.0.0.1:8094/v1"
  # The planner brain's model on the same router; its lease unloads this one.
  defp default(:planner_model), do: get(:code_model)
  defp default(:code_model_max_tokens), do: 16_384
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
