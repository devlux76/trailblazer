defmodule Trailblazer.Planner.Research.Children do
  @moduledoc "The research route's child cards: reply validation, planner adds, and child completion."

  alias Trailblazer.CaseStore
  alias Trailblazer.Planner.Route
  alias Trailblazer.Planner.Research.{Boundary, Journal, Support}

  @priorities ~w(p0 p1 p2 p3)
  @label "dispatch:ready"

  @doc false
  def summarise(refs, []), do: "children: " <> Enum.join(refs, ", ")

  def summarise(refs, drops),
    do: Enum.join([dropped_note(drops), summarise(refs, [])], "; ")

  defp dropped_note(drops),
    do: "dropped (" <> Integer.to_string(length(drops)) <> "): " <> Enum.join(drops, "; ")

  # One child must satisfy the route's own rules: not a research label again, a
  # non-empty title, an admitted repository, and a body that names files and
  # states acceptance and ordered implementation steps. The card's check proves the result.
  @doc false
  def analyze_child(child, names) when is_map(child) do
    title = Support.value(child, "title")
    repo = Support.value(child, "repo")
    files = List.wrap(Support.value(child, "files") || [])
    acceptance = Support.value(child, "acceptance")
    plan = Support.value(child, "plan")

    cond do
      "dispatch:research" in List.wrap(Support.value(child, "labels") || []) ->
        {:error, "a research-labelled child repeats the loop"}

      not (is_binary(title) and String.trim(title) != "") ->
        {:error, "no title"}

      not (is_binary(repo) and repo in names) ->
        {:error, "unknown repository"}

      not (is_binary(acceptance) and String.trim(acceptance) != "") ->
        {:error, "no acceptance criteria"}

      not (is_list(plan) and plan != [] and
               Enum.all?(plan, &(is_binary(&1) and String.trim(&1) != ""))) ->
        {:error, "no implementation plan"}

      not (files != [] and Enum.all?(files, &is_binary/1)) ->
        {:error, "the files do not parse as relative paths"}

      true ->
        body = compose(files, acceptance, plan)

        if Route.classify(%{"labels" => [], "body" => body}) == :trailblazer,
          do:
            {:ok,
             %{
               "title" => String.trim(title),
               "repo" => repo,
               "files" => files,
               "acceptance" => String.trim(acceptance),
               "plan" => plan,
               "priority" => priority_of(child)
             }},
          else: {:error, "the files do not parse as relative paths"}
    end
  end

  def analyze_child(_, _), do: {:error, "not an object"}

  # The basenames of the admitted repositories: a child names its repository
  # by that name and the add runs under the matching path.
  @doc false
  def names_of(%{config: %{repos: repos}}), do: Enum.map(Map.keys(repos), &Path.basename/1)
  def names_of(_), do: []

  defp compose(files, acceptance, plan) do
    steps =
      Enum.map_join(Enum.with_index(plan, 1), "; ", fn {step, n} ->
        "#{n}. #{String.replace(step, "\n", " ")}"
      end)

    "Files: " <>
      Enum.join(files, " ") <>
      "\nAcceptance: " <>
      acceptance <>
      "\nImplementation plan: " <> steps
  end

  defp priority_of(%{"priority" => p}) when p in @priorities, do: p
  defp priority_of(_), do: "p2"

  @doc false
  def add_child(child, state, row) do
    research = Support.research_of(state.config)

    args = [
      "--actor",
      research.actor,
      "add",
      child["repo"],
      "--title",
      child["title"],
      "--plan",
      compose_plan(child, row.ref),
      "--priority",
      child["priority"]
    ]

    case Boundary.perform(state.run, state.config, args) do
      {:error, tail} ->
        {:error, tail}

      {:ok, tail} ->
        case ref_of(tail) do
          {:ok, ref} ->
            [repo, bug] = String.split(ref, ":", parts: 2)
            apply_label(state.label, repo_path_of(state, repo), bug, @label)
            {:ok, ref}

          {:error, why} ->
            {:error, why}
        end
    end
  end

  defp compose_plan(child, parent) do
    compose(child["files"], child["acceptance"], child["plan"]) <>
      "\nChild of the research route for " <> parent <> "."
  end

  defp ref_of(tail) do
    case Jason.decode(String.slice(tail, -900, 900) |> String.trim()) do
      {:ok, %{"ref" => ref}} when is_binary(ref) -> {:ok, ref}
      _ -> {:error, "the add output does not end in a JSON object"}
    end
  end

  defp apply_label(nil, _, _, _), do: :ok

  defp apply_label(fun, path, bug, label) do
    if is_binary(path), do: fun.(path, bug, label)
    :ok
  end

  defp repo_path_of(state, name) do
    (Map.get(state.config || %{}, :repos) || %{})
    |> Enum.find_value(fn {path, _} -> if Path.basename(path) == name, do: path end)
  end

  # A child's completion arrives through the planner mirror; the parent ends
  # only when every one of its children is done.
  @doc false
  def child_done(child_ref, state) do
    parent =
      CaseStore.transaction(fn conn ->
        Enum.find(Journal.rows(conn), &(child_ref in List.wrap(&1.children || [])))
      end)

    case parent do
      nil -> state
      row -> finish(state, row, child_ref)
    end
  end

  defp finish(state, row, child_ref) do
    kids = row.children || []
    total = length(kids)
    done = (row.children_done || 0) + 1

    Journal.record(
      row.ref,
      row.state,
      "children completed " <> Integer.to_string(done) <> "/" <> Integer.to_string(total),
      row.conference,
      children_done: done
    )

    if done >= total,
      do:
        Boundary.perform(state.run, state.config, [
          "--actor",
          (Support.research_of(state.config) || %{})[:actor],
          "done",
          row.ref,
          "--evidence",
          child_list(kids, child_ref)
        ])

    state
  end

  defp child_list(kids, _ref), do: "researched children: " <> Enum.join(kids, ", ")
end
