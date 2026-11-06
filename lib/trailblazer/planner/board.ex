defmodule Trailblazer.Planner.Board do
  @moduledoc """
  Reads the planner board and dispatches one card (trailblazer:cf1c78a).

  `read/2` reads each admitted repository's board separately and turns it
  into at most eight candidate cards: an unclaimed todo card labelled
  `dispatch:ready` of an admitted repository with exactly one admitted check,
  never Trailblazer itself. `dispatch:ready` is the explicit authorization —
  the card's kind does not matter, so ready defect reports are dispatched the
  same as tasks. Everything else waits. Readiness is decided before the limit
  cuts, so a crowded board cannot starve its one ready card.

  Every planner call runs through the check runner (one process group, one
  backstop, a bounded output tail), and the default runner pipes the JSON
  through a bounding filter first: a reply can exceed the check tail's 4000
  characters — a board of a hundred cards, a card's body and comment
  history — and a truncated tail is not JSON.
  """

  alias Trailblazer.{Files, Loop.Check}
  alias Trailblazer.Planner.Route

  @limit 8
  @board_limit 100
  @limit_ms 60_000
  @research_default %{"actor" => "research", "session" => "trailblazer"}
  @actor ~r/\A[0-9A-Za-z][0-9A-Za-z_-]{0,31}\z/
  @session ~r/\A[^\x00-\x1f]{1,128}\z/
  # a bare peer identity: the base58 multihash the VORTEX CLI admits
  @peer ~r/\A[1-9A-HJ-NP-Za-km-z]{10,}\z/

  # Bounds a reply under the check tail. A board reply is stripped to the
  # eligibility facts per card (ref, actor, priority); a show reply keeps its
  # text bounded. Invalid JSON or an error object leaves through a non-zero
  # exit, which the check reports as a fail.
  @filter ~S'''
  import sys, json
  sys.stdout.reconfigure(encoding="utf-8")
  try:
      d = json.load(sys.stdin)
  except Exception:
      sys.exit(1)
  if not isinstance(d, dict) or "error" in d:
      print(json.dumps(d)[:2000] if isinstance(d, dict) else "")
      sys.exit(1)

  def cut(x, n):
      return x[:n] if isinstance(x, str) else x

  # The routing markers (Route) are lines anywhere in the body, and a plan
  # usually starts past the excerpt: a marker line not whole in the excerpt
  # follows it, bounded. A cut-off last line is dropped, so a half marker
  # line is never read first.
  MARKERS = ("Files:", "Acceptance:", "Implementation plan:")

  def body(b):
      if not isinstance(b, str):
          return b
      b = b.replace("\r\n", "\n")
      lines = b.split("\n")
      head = b[:400]
      if len(b) > 400:
          if "\n" in head:
              head = head[:head.rfind("\n")]
          elif head.startswith(MARKERS):
              head = ""
      whole = set(head.split("\n"))
      for m in MARKERS:
          line = next((l for l in lines if l.startswith(m)), None)
          if line is None or line in whole:
              continue
          if len(line) > 200:
              if m == "Files:":
                  # a path is never cut: no separator in reach drops the line
                  cut_at = max(line.rfind(",", 0, 200), line.rfind(" ", 0, 200))
                  if cut_at <= len(m):
                      continue
                  line = line[:cut_at]
              else:
                  line = line[:200]
          head += "\n" + line
      return head

  if isinstance(d.get("cards"), list):
      rows = []
      for c in d["cards"]:
          if isinstance(c, dict) and isinstance(c.get("ref"), str):
              rows.append([c["ref"], c.get("actor"), c.get("priority")])
      print(json.dumps({"cards": rows}, ensure_ascii=False))
  else:
      if "title" in d:
          d["title"] = cut(d["title"], 200)
      if "body" in d:
          d["body"] = body(d["body"])
      if isinstance(d.get("recent"), list):
          d["recent"] = [cut(c, 150) for c in d["recent"][:3]]
      if isinstance(d.get("claim"), dict) and isinstance(d["claim"].get("notes"), list):
          d["claim"]["notes"] = [{"n": n.get("n"), "action": cut(n.get("action"), 20),
                                  "text": cut(n.get("text"), 150)}
                                 for n in d["claim"]["notes"][-3:]]
      print(json.dumps(d, ensure_ascii=False))
  '''

  defstruct repos: %{}, planner: nil, research: nil

  @doc """
  Loads the admitted map from the JSON file named by `path`: `"repos"` maps
  absolute repository paths to their list of admitted checks, and the
  optional `"planner"` entry is the CLI path, or a list starting with the
  path plus extra arguments for the CLI. Paths are canonicalised.
  """
  def load_config!(path) do
    text =
      case File.read(path) do
        {:ok, text} -> text
        {:error, reason} -> raise ArgumentError, "planner config #{path}: #{reason}"
      end

    config =
      try do
        Jason.decode!(text)
      rescue
        error -> raise ArgumentError, "planner config #{path}: #{Exception.message(error)}"
      end

    repos =
      case config do
        %{"repos" => repos} when is_map(repos) ->
          Map.new(repos, fn
            {repo, checks} when is_binary(repo) and is_list(checks) ->
              unless String.starts_with?(repo, "/") and Enum.all?(checks, &is_binary/1) do
                raise ArgumentError, "planner config repos must map absolute paths to checks"
              end

              {:ok, path} = Files.canonical_path(repo)
              {path, checks}

            _ ->
              raise ArgumentError, "planner config repos must map paths to check lists"
          end)

        _ ->
          raise ArgumentError, "planner config needs a repos map"
      end

    planner =
      case config do
        %{"planner" => nil} ->
          {Path.expand("~/.local/bin/planner"), []}

        %{"planner" => [cmd | extra]} when is_binary(cmd) ->
          unless Enum.all?(extra, &is_binary/1),
            do: raise(ArgumentError, "planner config planner extras must be strings")

          {cmd, extra}

        %{"planner" => cmd} when is_binary(cmd) ->
          {cmd, []}

        %{"planner" => other} ->
          raise ArgumentError,
                "planner config planner must be a path or [path | args], got " <>
                  inspect(other)

        %{} ->
          {Path.expand("~/.local/bin/planner"), []}
      end

    %__MODULE__{repos: repos, planner: planner, research: research(config["research"])}
  end

  @doc """
  The candidate cards, or `{:error, {:planner, tail}}` when a call fails.
  `opts[:self]` is the one repository never eligible (the running node's own
  checkout); `opts[:run]` replaces the runner, receiving the planner argv and
  returning the check-shaped result map.
  """
  def read(config, opts \\ []) do
    run = runner(config, opts)
    self = self_path(opts)

    # One admitted repository at a time, so a crowded unadmitted board cannot
    # push admitted work out of the read. A repository is read when it has
    # exactly one admitted check and its directory name is unambiguous among
    # the admitted paths (the planner names boards by basename).
    repos =
      config.repos
      |> Enum.reject(fn {path, _} -> path == self end)
      |> Enum.reject(fn {_path, checks} -> length(checks) != 1 end)
      |> Enum.reject(fn {path, _} -> ambiguous?(config.repos, path) end)
      |> Enum.sort()

    with {:ok, cards} <-
           Enum.reduce_while(repos, {:ok, []}, fn {repo, [check]}, {:ok, acc} ->
             case repo_candidates(run, repo, check, self) do
               {:ok, cards} -> {:cont, {:ok, acc ++ cards}}
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end) do
      # a failed card sorts after fresh work of its priority
      cards =
        cards
        |> Enum.sort_by(&{&1.context["priority"] || "p2", &1.context["failed"] == true, &1.ref})
        |> Enum.take(@limit)

      fingerprint =
        cards
        |> Enum.map(&%{ref: &1.ref, check: &1.check, context: &1.context})
        |> Jason.encode!()
        |> sha256()

      {:ok, %{cards: cards, fingerprint: fingerprint}}
    end
  end

  @doc """
  Claims the card for this worker with the existing assignment command:
  `planner --actor trailblazer assign REF trailblazer --check CHECK [--file PATH]...`,
  one `--file` per path on the card's `Files:` line.
  """
  def assign(config, %{ref: ref, check: check} = card, opts \\ []) do
    run = runner(config, opts)

    # The card's `Files:` (Route-parsed) go along, so the coder gets their
    # source in its prompt instead of spending its window reading them.
    # `--file=PATH` as one argument: a path starting with "-" stays a value
    files = Enum.map(card_files(card), &("--file=" <> &1))
    args = ["--actor", "trailblazer", "assign", ref, "trailblazer", "--check", check] ++ files

    # a retried failed card: Trailblazer's own block is released first, so
    # the planner CLI records the failed case in the new assignment's history
    released =
      case card do
        %{context: %{"failed" => true}} ->
          run.([
            "--actor",
            "trailblazer",
            "release",
            ref,
            "retry chosen by the planner after a failed case"
          ])

        _ ->
          %{status: :pass}
      end

    case released do
      %{status: :pass} ->
        case {assign_now(run, args), card} do
          {{:error, _} = error, %{context: %{"failed" => true, "failure" => reason}}} ->
            # released but not assigned: blocked again with its reason, so it
            # never reads as fresh work
            run.(["--actor", "trailblazer", "block", ref, reason])
            error

          {result, _} ->
            result
        end

      result ->
        {:error, {:planner, result.output_tail}}
    end
  end

  defp assign_now(run, args) do
    case run.(args) do
      %{status: :pass} -> :ok
      result -> {:error, {:planner, result.output_tail}}
    end
  end

  @doc """
  Runs planner CLI `args` through the check runner (the same channel `read/2`
  and `assign/3` use), so a research server's own commands stay bounded and
  observed. `opts[:run]` replaces the runner.
  """
  def run(config, args, opts \\ []), do: runner(config, opts).(args)

  @doc """
  The refs of every card in progress (`doing`, on any board) whose actor is
  one of `actors`: `{:ok, refs}` or `{:error, reason}`. The research route
  asks it whether OpenCode already holds an assignment.
  """
  def held_by(config, actors, opts \\ []) do
    with {:ok, %{"cards" => rows}} when is_list(rows) <-
           json(runner(config, opts), ["board", "--column", "doing", "--limit", "500"]) do
      {:ok, for([ref, actor | _] <- rows, actor in actors, do: ref)}
    else
      {:ok, other} -> {:error, {:planner, inspect(other, limit: 5)}}
      {:error, _} = error -> error
    end
  end

  # The optional `"research"` entry: the VORTEX peer id of the research agent,
  # its planner actor and the conference session. The defaults keep to the
  # planner CLI's own actor rules; anything else is refused at load.
  defp research(nil), do: nil

  defp research(%{"peer" => peer} = entry) when is_binary(peer) and peer != "" do
    if Map.keys(entry) -- ["peer", "actor", "session"] != [] do
      raise ArgumentError, "planner config research admits only peer, actor and session"
    end

    actor = entry["actor"]
    session = entry["session"]

    if actor != nil and not (is_binary(actor) and Regex.match?(@actor, actor)) do
      raise ArgumentError, "planner config research actor must be a short name"
    end

    if session != nil and not (is_binary(session) and Regex.match?(@session, session)) do
      raise ArgumentError, "planner config research session must be a plain name"
    end

    unless Regex.match?(@peer, peer) do
      raise ArgumentError, "planner config research peer must be a bare peer identity"
    end

    entry = Map.merge(@research_default, entry)
    %{peer: peer, actor: entry["actor"], session: entry["session"]}
  end

  defp research(_), do: raise(ArgumentError, "planner config research must name a peer")

  ## Candidates

  # The whole todo board of one admitted repository, then the show call
  # decides readiness per card. Only unclaimed ready cards survive; the
  # eight-card cut happens after all repositories have been filtered.
  defp repo_candidates(run, repo, check, self) do
    name = repo_name(repo)

    # todo cards, and blocked ones: a card Trailblazer blocked after a failed
    # case comes back to the planner with the reason (shown/6)
    Enum.reduce_while(["todo", "blocked"], {:ok, []}, fn column, {:ok, acc} ->
      case json(run, ["board", "--repo", name, "--column", column, "--limit", "#{@board_limit}"]) do
        {:ok, board} ->
          {:cont,
           {:ok,
            acc ++ Enum.flat_map(board_cards(board), &shown(run, &1, repo, check, name, self))}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp board_cards(%{"cards" => cards}) when is_list(cards), do: cards
  defp board_cards(_), do: []

  # A board row is [ref, actor, priority]. The show call decides unclaimed,
  # ready and todo afresh — the row only bounds the show calls and carries
  # the priority into the context.
  defp shown(run, row, repo, check, name, self) do
    with [ref, _actor, priority] when is_binary(ref) <- row,
         true <- String.starts_with?(ref, name <> ":") and repo != self,
         {:ok, shown} <- json(run, ["show", ref]),
         {:ok, failure} <- standing(shown),
         true <- is_list(shown["labels"]) and "dispatch:ready" in shown["labels"],
         title when is_binary(title) <- shown["title"] do
      labels = shown["labels"]
      body = shown["body"] || ""
      files = of_files(Route.parse_files(body))

      [
        %{
          ref: ref,
          check: check,
          repo: repo,
          context:
            %{
              "ref" => ref,
              "repo" => name,
              "title" => title,
              "body" => body,
              "priority" => priority,
              "recent" => Enum.take(shown["recent"] || [], 3),
              "check" => check,
              # the routing facts (bug:4cc63df): the fetched labels and the
              # routes the body's own markers admit to
              "labels" => labels,
              "files" => files,
              "route" => to_string(Route.classify(%{"labels" => labels, "body" => body}))
            }
            |> failed(failure)
        }
      ]
    else
      _ -> []
    end
  end

  # Which cards stand: an unclaimed or released (claim back at todo) todo
  # card, or a card Trailblazer itself blocked after a failed case. The block
  # note is the reason the planner is told; any other blocked or owned card
  # is not the planner's to dispatch.
  defp standing(%{"column" => "todo", "claim" => nil}), do: {:ok, nil}
  defp standing(%{"column" => "todo", "claim" => %{"state" => "todo"}}), do: {:ok, nil}

  # A failed card is offered back once: after a second failed case it stays
  # blocked for the frontier or the operator, so a small planner cannot keep
  # re-picking a card that keeps timing out. `assignments` is the planner
  # CLI's count (current plus released); a blocked card was assigned at least once.
  @retries 1

  defp standing(
         %{
           "column" => "blocked",
           "claim" => %{"actor" => "trailblazer", "state" => "blocked"} = claim
         } = shown
       ) do
    assigned =
      case shown["assignments"] do
        n when is_integer(n) and n > 1 -> n
        _ -> 1
      end

    if assigned > @retries, do: :skip, else: {:ok, {blocked_reason(claim), assigned}}
  end

  defp standing(_), do: :skip

  defp blocked_reason(claim) do
    notes = if is_list(claim["notes"]), do: claim["notes"], else: []

    reason =
      notes
      |> Enum.filter(&(is_map(&1) and &1["action"] == "block" and is_binary(&1["text"])))
      |> List.last()

    (reason && reason["text"]) || "blocked by Trailblazer"
  end

  defp failed(context, nil), do: context

  defp failed(context, {reason, assigned}),
    do: Map.merge(context, %{"failed" => true, "failure" => reason, "failures" => assigned})

  # A parsed file list is context data even when empty; only a parse error has
  # nothing on the card to name.
  defp card_files(%{context: %{"files" => files}}) when is_list(files),
    do: Enum.filter(files, &is_binary/1)

  defp card_files(_), do: []

  defp of_files({:ok, files}) when is_list(files), do: files
  defp of_files(_), do: []

  # A cross-repository .bugs tree is "shared" on the planner's board.
  defp repo_name(path) do
    case Path.basename(path) do
      ".bugs" -> "shared"
      name -> name
    end
  end

  # Two admitted paths with the same directory name are ambiguous: the
  # board name cannot say which one a card belongs to, so neither is read.
  defp ambiguous?(repos, path) do
    name = repo_name(path)
    Enum.count(repos, fn {other, _} -> repo_name(other) == name end) != 1
  end

  defp self_path(opts) do
    case opts[:self] do
      nil ->
        {:ok, path} = Files.canonical_path(File.cwd!())
        path

      path ->
        {:ok, canon} = Files.canonical_path(path)
        canon
    end
  end

  ## The runner

  defp runner(config, opts) do
    case opts[:run] do
      nil -> fn args -> check_run(config, args) end
      fun when is_function(fun, 1) -> fun
    end
  end

  # Like Companion's planner mirror: the CLI with its extra arguments under
  # the check PATH, piped through the bounding filter so a reply survives the
  # check's bounded tail whole.
  defp check_run(config, args) do
    {cmd, extra} = config.planner
    path = Enum.join([Path.expand("~/.local/bin"), System.get_env("PATH", "")], ":")
    argv = ["env", "PATH=" <> path, cmd] ++ extra ++ args

    command =
      Enum.map_join(argv, " ", &shell_quote/1) <>
        " | python3 -c " <> shell_quote(@filter)

    limit = @limit_ms
    Check.run(File.cwd!(), command, timeout: limit)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp json(run, args) do
    case run.(args) do
      %{status: :pass, output_tail: tail} when is_binary(tail) ->
        case Jason.decode(tail) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, {:planner, tail}}
        end

      result ->
        {:error, {:planner, Map.get(result, :output_tail) || "no output"}}
    end
  end

  defp sha256(text), do: Base.encode16(:crypto.hash(:sha256, text), case: :lower)
end
