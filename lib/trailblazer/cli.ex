defmodule Trailblazer.CLI do
  @moduledoc """
  The `trailblazer` command: `trailblazer <op> [--repo DIR] [args]`, one op per
  route of the local API. It reads `endpoint.json` from the state directory on
  every call, sends the request with the bearer token, prints the JSON reply on
  stdout, and exits 0, or 1 on an error reply.

      trailblazer watch
      trailblazer status
      trailblazer where NAME | PATH:LINE
      trailblazer uses NAME | ID
      trailblazer impact NAME | ID [--depth N]
      trailblazer read PATH:FIRST-LAST [--text]
      trailblazer search TEXT [--limit N]
      trailblazer trail REQUEST [--file PATH]... [--budget N] [--text]
      trailblazer stale_citations
      trailblazer run REQUEST [--file PATH]... [--design TEXT]... [--check CMD] [--no-wait]
      trailblazer case ID [--follow]
      trailblazer anomalies [--all]
      trailblazer ack ID

  `--repo` defaults to the git root of the current directory. Everything after
  `--` is text, so `trailblazer search -- --version` searches for `--version`.
  Arguments are never handed to a shell (A10 in the register).
  """

  alias Trailblazer.Config

  @ops ~w(watch status where uses impact read search trail stale_citations run case anomalies ack vortex vortex_status)
  @no_repo ~w(case anomalies ack vortex vortex_status)
  @switches [
    repo: :string,
    file: :keep,
    design: :keep,
    check: :string,
    wait: :boolean,
    budget: :integer,
    depth: :integer,
    limit: :integer,
    text: :boolean,
    all: :boolean,
    follow: :boolean
  ]
  @not_running %{
    "error" => "trailblazer is not running",
    "hint" => "systemctl --user start trailblazer"
  }

  @doc false
  def main(argv) do
    {:ok, _} = Application.ensure_all_started(:req)
    {code, out} = run(argv)
    IO.puts(out)
    System.halt(code)
  end

  @doc "Runs one command; returns the exit code and what to print."
  @spec run([String.t()], keyword()) :: {0 | 1, String.t()}
  def run(argv, opts \\ []) do
    case parse(argv) do
      {:ok, op, body, flags} -> call(op, body, flags, opts)
      {:error, message} -> {1, encode(%{"error" => message, "usage" => usage()})}
    end
  end

  @doc "The op, the request body and the flags of a command line."
  @spec parse([String.t()]) :: {:ok, String.t(), map(), keyword()} | {:error, String.t()}
  def parse(argv) do
    {before, literal} = split_literal(argv)

    case OptionParser.parse(before, strict: @switches) do
      {flags, [op | args], []} when op in @ops ->
        # case, anomalies and ack are about the service, not a repository
        with {:ok, repo} <- if(op in @no_repo, do: {:ok, nil}, else: repo(flags[:repo])),
             {:ok, body} <- body(op, args ++ literal, flags) do
          {:ok, op, if(op in @no_repo, do: body, else: Map.put(body, "repo", repo)), flags}
        end

      {_flags, [op | _], []} ->
        {:error, "unknown op #{inspect(op)}"}

      {_flags, [], []} ->
        {:error, "no op given"}

      {_flags, _args, [{flag, _} | _]} ->
        {:error, "bad option #{flag}"}
    end
  end

  defp split_literal(argv) do
    case Enum.split_while(argv, &(&1 != "--")) do
      {before, ["--" | rest]} -> {before, rest}
      {before, []} -> {before, []}
    end
  end

  defp body(op, [], _flags) when op in ~w(vortex vortex_status), do: {:ok, %{}}

  defp body(op, [], _flags) when op in ~w(watch status stale_citations), do: {:ok, %{}}

  defp body("where", [arg], _flags) do
    case position(arg) do
      {path, line} -> {:ok, %{"path" => path, "line" => line}}
      nil -> {:ok, %{"name" => arg}}
    end
  end

  defp body("uses", [arg], _flags), do: {:ok, ref(arg)}

  defp body("impact", [arg], flags),
    do: {:ok, ref(arg) |> put_flag("depth", flags[:depth])}

  defp body("read", [arg], _flags) do
    case Regex.run(~r/\A(.+):(\d+)-(\d+)\z/s, arg) do
      [_, path, first, last] ->
        {first, last} = {String.to_integer(first), String.to_integer(last)}

        if first >= 1 and last >= first,
          do: {:ok, %{"path" => path, "first" => first, "last" => last}},
          else: {:error, "read wants PATH:FIRST-LAST with 1 <= FIRST <= LAST"}

      nil ->
        {:error, "read wants PATH:FIRST-LAST"}
    end
  end

  defp body("search", [text], flags),
    do: {:ok, %{"text" => text} |> put_flag("limit", flags[:limit])}

  defp body("trail", [request], flags) do
    files = Keyword.get_values(flags, :file)

    {:ok,
     %{"request" => request}
     |> then(&if(files == [], do: &1, else: Map.put(&1, "files", files)))
     |> put_flag("budget", flags[:budget])}
  end

  defp body("run", [request], flags) do
    {:ok,
     %{"request" => request}
     |> put_flag("files", Keyword.get_values(flags, :file))
     |> put_flag("design", Keyword.get_values(flags, :design))
     |> put_flag("check", flags[:check])}
  end

  defp body("case", [id], _flags), do: {:ok, %{"case" => id}}
  defp body("anomalies", [], flags), do: {:ok, put_flag(%{}, "all", flags[:all])}

  defp body("ack", [id], _flags) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, %{"id" => n}}
      _ -> {:error, "ack takes an anomaly id"}
    end
  end

  defp body(op, args, _flags), do: {:error, "#{op} does not take #{inspect(args)}"}

  defp position(arg) do
    case Regex.run(~r/\A(.+):(\d+)\z/s, arg) do
      [_, path, line] -> {path, String.to_integer(line)}
      nil -> nil
    end
  end

  defp ref(arg) do
    case Integer.parse(arg) do
      {id, ""} -> %{"id" => id}
      _name -> %{"name" => arg}
    end
  end

  defp put_flag(map, _key, nil), do: map
  defp put_flag(map, key, value), do: Map.put(map, key, value)

  defp repo(nil) do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      _not_git -> {:ok, File.cwd!()}
    end
  rescue
    _no_git -> {:ok, File.cwd!()}
  end

  defp repo(dir), do: {:ok, Path.expand(dir)}

  ## Calling the service

  defp call(op, body, flags, opts) do
    state_dir = Keyword.get(opts, :state_dir, Config.get(:state_dir))

    with {:ok, %{"url" => url, "token" => token}} <- endpoint(state_dir),
         :post <- if(op == "case" and flags[:follow], do: :follow, else: :post),
         {:ok, status, reply} <- post(url, token, op, body, opts) do
      code = if status < 400 and not error?(reply), do: 0, else: 1

      case {flags[:text] && code == 0, op, reply} do
        {_, "run", %{"case" => id}} when code == 0 ->
          if flags[:wait] == false,
            do: {0, encode(reply)},
            else: follow_case(url, token, id, opts)

        {_, "case", %{"record" => record}} when code == 0 ->
          summary = reply |> Map.delete("record") |> Map.put("task", record["task"])
          {0, encode(summary)}

        {true, "trail", %{"text" => text}} when is_binary(text) ->
          {0, text}

        {true, "read", text} when is_binary(text) ->
          {0, text}

        {true, "read", %{"text" => text}} when is_binary(text) ->
          {0, text}

        # an error with no JSON body still says what happened (E23)
        _json when code == 1 and not is_map(reply) ->
          {1, encode(%{"error" => "the service answered HTTP #{status}", "body" => reply})}

        _json ->
          {code, encode(reply)}
      end
    else
      :follow ->
        {:ok, %{"url" => url, "token" => token}} = endpoint(state_dir)
        follow_case(url, token, body["case"], opts)

      _not_running ->
        {1, encode(@not_running)}
    end
  end

  # The case's events as the service records them (design §13.3): each is
  # printed as it comes (stderr, or opts[:on_event]), the report goes to
  # stdout. No polling and no receive timeout: the service either sends the
  # next line or closes the connection.
  defp follow_case(url, token, id, opts) do
    on_event = Keyword.get(opts, :on_event, &IO.puts(:stderr, event_line(&1)))
    key = {__MODULE__, :follow, make_ref()}
    Process.put(key, {"", nil})

    into = fn {:data, data}, acc ->
      {buffer, report} = Process.get(key)
      [rest | lines] = (buffer <> data) |> String.split("\n") |> Enum.reverse()

      report =
        lines
        |> Enum.reverse()
        |> Enum.reduce(report, fn line, report ->
          case Jason.decode(line) do
            {:ok, %{"report" => r}} ->
              r

            {:ok, %{"event" => e}} ->
              on_event.(e)
              report

            _ ->
              report
          end
        end)

      Process.put(key, {rest, report})
      {:cont, acc}
    end

    request =
      Req.new(
        url: String.trim_trailing(url, "/") <> "/case",
        json: %{"case" => id, "follow" => true},
        headers: [{"authorization", "Bearer " <> token}],
        receive_timeout: :infinity,
        retry: false,
        into: into
      )
      |> Req.merge(Keyword.get(opts, :req_options, []))

    result = Req.post(request)
    {_rest, report} = Process.delete(key)

    case {result, report} do
      {_, %{} = report} ->
        {if(report["status"] == "fixed", do: 0, else: 1), encode(report)}

      {{:ok, %Req.Response{status: status}}, nil} when status >= 400 ->
        {1, encode(%{"error" => "the service answered HTTP #{status}", "case" => id})}

      {{:ok, _}, nil} ->
        {1, encode(%{"error" => "the case's stream ended without a report", "case" => id})}

      {{:error, _}, nil} ->
        {1, encode(Map.put(@not_running, "case", id))}
    end
  end

  defp event_line(%{"seq" => seq, "kind" => kind, "data" => data}) do
    "#{seq} #{kind} " <> (data |> Jason.encode!() |> String.slice(0, 160))
  end

  defp event_line(e), do: inspect(e)

  defp endpoint(state_dir) do
    with {:ok, text} <- File.read(Path.join(state_dir, "endpoint.json")),
         {:ok, %{"url" => _, "token" => _} = endpoint} <- Jason.decode(text) do
      {:ok, endpoint}
    end
  end

  defp post(url, token, op, body, opts) do
    request =
      Req.new(
        url: String.trim_trailing(url, "/") <> "/" <> op,
        json: body,
        headers: [{"authorization", "Bearer " <> token}],
        # the local service answers or closes the connection; it is never
        # given up on because of a clock (design §13.2)
        receive_timeout: :infinity,
        retry: false
      )
      |> Req.merge(Keyword.get(opts, :req_options, []))

    case Req.post(request) do
      {:ok, %Req.Response{status: status, body: reply}} -> {:ok, status, reply}
      {:error, _} = error -> error
    end
  end

  defp error?(%{"error" => _}), do: true
  defp error?(_reply), do: false

  defp encode(term), do: Jason.encode!(term, pretty: true)

  defp usage, do: @moduledoc |> String.split("\n\n") |> Enum.at(1) |> String.trim()
end
