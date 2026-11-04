defmodule Trailblazer.Vortex.Settings do
  @moduledoc "Trusted local VORTEX policy; never sourced from a peer message."
  alias Trailblazer.Files
  alias Trailblazer.Loop.Artifacts

  def load(path) do
    {:ok, decode!(path)}
  rescue
    _ -> {:error, :invalid_config}
  end

  def load!(path) do
    case load(path) do
      {:ok, options} -> options
      {:error, _} -> raise ArgumentError, "invalid local VORTEX configuration"
    end
  end

  defp decode!(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"endpoint" => endpoint, "owner_peer" => owner, "peers" => peers} = config} <-
           Jason.decode(bytes),
         true <- is_binary(endpoint) and Path.type(endpoint) == :absolute,
         true <- is_binary(owner) and is_list(peers) do
      policies =
        Map.new(peers, fn %{"peer" => peer, "room" => room, "role" => role} = policy ->
          {:ok, members} = Jason.decode(room)
          true = Enum.sort(members) == Enum.sort([owner, peer])

          role =
            case role do
              "caller" -> :caller
              "frontier" -> :frontier
              "collaborator" -> :collaborator
            end

          repos =
            Map.new(Map.get(policy, "repos", %{}), fn {repo, checks} ->
              true =
                is_binary(repo) and Path.type(repo) == :absolute and is_list(checks) and
                  Enum.all?(checks, &is_binary/1)

              {:ok, canonical} = Files.canonical_path(repo)
              {canonical, checks}
            end)

          {:ok, artifacts} = Artifacts.policies(Map.get(policy, "artifacts"), repos)
          {peer, %{room: room, role: role, repos: repos, artifacts: artifacts}}
        end)

      options = [endpoint: endpoint, owner_peer: owner, peers: policies, listen: true]

      {:ok, permissions} =
        Trailblazer.Planner.PermissionPolicy.parse(config["permissions"], policies)

      options = if permissions, do: Keyword.put(options, :permissions, permissions), else: options

      case config["resource_mode"] do
        nil ->
          options

        "dedicated" ->
          Keyword.merge(options,
            resource_mode: :dedicated,
            resource:
              {&Trailblazer.Vortex.Resource.acquire/1, &Trailblazer.Vortex.Resource.release/1}
          )

        _ ->
          raise ArgumentError, "invalid resource mode"
      end
    else
      _ -> raise ArgumentError, "invalid local VORTEX configuration"
    end
  end
end
