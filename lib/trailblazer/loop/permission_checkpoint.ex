defmodule Trailblazer.Loop.PermissionCheckpoint do
  @moduledoc """
  Private, digest-bound preservation of a quiescent owned worktree and case files.
  Capture never deletes the source. Restore materializes files in a NEW directory,
  not a Git checkout; the continuation must separately revalidate Git ownership/base.
  Symlinks are saved as link text, never traversed. This is change detection, not
  a sandbox: the caller must stop the writer before capture or restore.
  """
  import Bitwise
  alias Trailblazer.Loop.{CaseRecord, Workspace}
  @archive "permission-checkpoints"

  # after_capture is a deterministic race-test hook, never persisted or supplied
  # by a model/transport. Production callers must leave it unset.
  def capture(case_id, ws, payload, opts \\ []) do
    protect(fn ->
      record = CaseRecord.get(case_id, inline: false) || fail(:no_case)

      identity =
        case Workspace.identity(ws, record.repo) do
          {:ok, identity} -> identity
          _ -> fail(:workspace_mismatch)
        end

      git = git_state(ws.path)

      unless git["head"] == ws.base and ws.branch == "trailblazer/" <> case_id,
        do: fail(:workspace_mismatch)

      case_root = CaseRecord.dir(case_id)
      ensure_dir!(case_root)
      store = Path.join(case_root, @archive)
      ensure_dir!(store)
      staging = Path.join(store, "capture-" <> random())
      File.mkdir!(staging)
      File.chmod!(staging, 0o700)
      File.mkdir!(Path.join(staging, "blobs"))
      File.chmod!(Path.join(staging, "blobs"), 0o700)
      roots = [{"worktree", ws.path}, {"case", case_root}]
      entries = inventory(roots, staging)

      manifest = %{
        "version" => 1,
        "case_id" => case_id,
        "identity" => Jason.decode!(Jason.encode!(identity)),
        "git" => git,
        "entries" => entries,
        "payload" => put_bytes(staging, Jason.encode!(payload)),
        "journal" => put_bytes(staging, Jason.encode!(record))
      }

      if hook = opts[:after_capture], do: hook.()

      unless entries == inventory(roots, nil) and record == CaseRecord.get(case_id, inline: false) and
               git == git_state(ws.path),
             do: fail(:source_changed)

      bytes = Jason.encode!(manifest)
      sha = hash(bytes)
      private_write!(Path.join(staging, "manifest.json"), bytes)
      final = Path.join(store, sha)

      case File.rename(staging, final) do
        :ok -> :ok
        {:error, reason} when reason in [:eexist, :enotempty] -> :ok
        {:error, _} -> fail(:storage_failed)
      end

      ref = %{"version" => 1, "sha256" => sha}
      # A reference is issued only after reading back the published copy.
      load!(case_id, ref)
      {:ok, ref}
    end)
  end

  def verify(case_id, ref), do: protect(fn -> {:ok, load!(case_id, ref)} end)

  def restore(case_id, ref, destination) do
    protect(fn ->
      saved = load!(case_id, ref)
      destination = Path.expand(destination)
      directories!(Path.dirname(destination))

      case File.mkdir(destination) do
        :ok -> File.chmod!(destination, 0o700)
        {:error, :eexist} -> fail(:destination_exists)
        {:error, _} -> fail(:unsafe_path)
      end

      entries = saved["manifest"]["entries"]
      store = archive(case_id, ref)
      # All directory parents are verified real directories before any leaf write.
      for e <- entries, e["type"] == "directory" do
        path = target(destination, e)
        directories!(Path.dirname(path))
        File.mkdir!(path)
      end

      for e <- entries, e["type"] != "directory" do
        path = target(destination, e)
        directories!(Path.dirname(path))

        case e["type"] do
          "file" ->
            bytes_path = blob_path(store, e["sha256"])
            {:ok, output} = File.open(path, [:write, :binary, :exclusive, :sync])

            try do
              for chunk <- File.stream!(bytes_path, 65_536), do: IO.binwrite(output, chunk)
            after
              File.close(output)
            end

            unless file_digest(path) == Map.take(e, ["sha256", "size"]),
              do: fail(:invalid_checkpoint)

            File.chmod!(path, e["mode"])

          "symlink" ->
            File.ln_s!(e["target"], path)
        end
      end

      # Children first: restrictive directory modes must not block restoration.
      for e <- Enum.reverse(entries),
          e["type"] == "directory",
          do: File.chmod!(target(destination, e), e["mode"])

      {:ok, saved}
    end)
  end

  defp load!(case_id, ref) do
    unless is_map(ref) and Map.keys(ref) |> Enum.sort() == ["sha256", "version"],
      do: fail(:invalid_checkpoint)

    unless ref["version"] == 1 and digest?(ref["sha256"]), do: fail(:invalid_checkpoint)
    unless CaseRecord.get(case_id, inline: false), do: fail(:no_case)
    store = archive(case_id, ref)
    bytes = read_regular!(Path.join(store, "manifest.json"))
    unless hash(bytes) == ref["sha256"], do: fail(:invalid_checkpoint)
    m = Jason.decode!(bytes)

    unless is_map(m) and m["version"] == 1 and m["case_id"] == case_id and is_list(m["entries"]) and
             Enum.all?(m["entries"], &valid_entry?/1),
           do: fail(:invalid_checkpoint)

    entries = m["entries"]

    unless Enum.sort(for e <- entries, e["path"] == "", do: e["area"]) == ["case", "worktree"],
      do: fail(:invalid_checkpoint)

    keys = Enum.map(entries, &{&1["area"], &1["path"]})
    unless Enum.uniq(keys) == keys, do: fail(:invalid_checkpoint)

    for e <- entries do
      unless valid_entry?(e), do: fail(:invalid_checkpoint)

      if e["path"] != "" do
        parent = Path.dirname(e["path"])
        parent = if parent == ".", do: "", else: parent

        unless Enum.any?(
                 entries,
                 &(&1["area"] == e["area"] and &1["path"] == parent and &1["type"] == "directory")
               ),
               do: fail(:invalid_checkpoint)
      end

      if e["type"] == "file", do: verify_blob!(store, e)
    end

    payload = verify_blob!(store, m["payload"]) |> File.read!() |> Jason.decode!()
    journal = verify_blob!(store, m["journal"]) |> File.read!() |> Jason.decode!()
    %{"manifest" => m, "payload" => payload, "journal" => journal}
  end

  defp valid_entry?(e) when is_map(e) do
    path = e["path"]

    e["area"] in ["worktree", "case"] and is_binary(path) and
      (path == "" or
         (Path.type(path) == :relative and
            Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", "..", ".git"])))) and
      not String.contains?(path, <<0>>) and
      case e["type"] do
        "directory" ->
          mode?(e["mode"])

        "file" ->
          path != "" and mode?(e["mode"]) and digest?(e["sha256"]) and is_integer(e["size"]) and
            e["size"] >= 0

        "symlink" ->
          path != "" and is_binary(e["target"]) and not String.contains?(e["target"], <<0>>)

        _ ->
          false
      end
  end

  defp valid_entry?(_), do: false

  defp inventory(roots, store) do
    Enum.flat_map(roots, fn {area, root} ->
      directories!(root)
      walk(root, "", area, store)
    end)
  end

  defp walk(root, rel, area, store) do
    path = if rel == "", do: root, else: Path.join(root, rel)
    stat = File.lstat!(path)
    entry = %{"area" => area, "path" => rel}

    case stat.type do
      :directory ->
        children =
          File.ls!(path)
          |> Enum.sort()
          |> Enum.reject(fn name ->
            rel == "" and
              ((area == "worktree" and name == ".git") or (area == "case" and name == @archive))
          end)

        [
          Map.merge(entry, %{"type" => "directory", "mode" => band(stat.mode, 0o7777)})
          | Enum.flat_map(children, fn name ->
              if name == ".git", do: fail(:unsupported_file)
              walk(root, if(rel == "", do: name, else: rel <> "/" <> name), area, store)
            end)
        ]

      :regular ->
        description = if store, do: put_file(store, path), else: file_digest(path)

        unless Map.take(stat, [:inode, :major_device, :minor_device, :size, :mode, :mtime, :ctime]) ==
                 Map.take(File.lstat!(path), [
                   :inode,
                   :major_device,
                   :minor_device,
                   :size,
                   :mode,
                   :mtime,
                   :ctime
                 ]),
               do: fail(:source_changed)

        [
          Map.merge(
            entry,
            Map.merge(description, %{"type" => "file", "mode" => band(stat.mode, 0o7777)})
          )
        ]

      :symlink ->
        [Map.merge(entry, %{"type" => "symlink", "target" => File.read_link!(path)})]

      _ ->
        fail(:unsupported_file)
    end
  end

  defp put_file(store, path) do
    copy = Path.join(store, "copy-" <> random())
    File.cp!(path, copy)
    File.chmod!(copy, 0o600)
    {:ok, io} = File.open(copy, [:read, :write, :binary])

    try do
      :ok = :file.sync(io)
    after
      File.close(io)
    end

    descriptor = file_digest(copy)
    File.rename!(copy, blob_path(store, descriptor["sha256"]))
    descriptor
  end

  defp put_bytes(store, bytes) do
    descriptor = %{"sha256" => hash(bytes), "size" => byte_size(bytes)}
    private_write!(blob_path(store, descriptor["sha256"]), bytes)
    descriptor
  end

  defp verify_blob!(store, d) when is_map(d) do
    unless digest?(d["sha256"]) and is_integer(d["size"]) and d["size"] >= 0,
      do: fail(:invalid_checkpoint)

    path = blob_path(store, d["sha256"])
    directories!(Path.dirname(path))

    unless File.lstat!(path).type == :regular and
             file_digest(path) == Map.take(d, ["sha256", "size"]),
           do: fail(:invalid_checkpoint)

    path
  end

  defp verify_blob!(_, _), do: fail(:invalid_checkpoint)

  defp file_digest(path) do
    {ctx, size} =
      Enum.reduce(File.stream!(path, 65_536), {:crypto.hash_init(:sha256), 0}, fn bytes,
                                                                                  {ctx, size} ->
        {:crypto.hash_update(ctx, bytes), size + byte_size(bytes)}
      end)

    %{"sha256" => Base.encode16(:crypto.hash_final(ctx), case: :lower), "size" => size}
  end

  defp read_regular!(path) do
    directories!(Path.dirname(path))
    unless File.lstat!(path).type == :regular, do: fail(:invalid_checkpoint)
    File.read!(path)
  end

  defp ensure_dir!(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        directories!(path)

      {:error, :enoent} ->
        ensure_dir!(Path.dirname(path))
        File.mkdir!(path)
        File.chmod!(path, 0o700)

      _ ->
        fail(:unsafe_path)
    end
  end

  defp directories!(path) do
    [root | parts] = Path.split(Path.expand(path))

    Enum.reduce(parts, root, fn part, parent ->
      current = Path.join(parent, part)
      unless File.lstat!(current).type == :directory, do: fail(:unsafe_path)
      current
    end)

    :ok
  end

  defp private_write!(path, bytes) do
    File.write!(path, bytes, [:sync])
    File.chmod!(path, 0o600)
  end

  defp archive(id, ref), do: Path.join([CaseRecord.dir(id), @archive, ref["sha256"]])

  defp git_state(root) do
    head = git!(root, ["rev-parse", "HEAD"])
    index = git!(root, ["rev-parse", "--path-format=absolute", "--git-path", "index"])
    %{"head" => head, "index" => if(File.exists?(index), do: file_digest(index), else: nil)}
  end

  defp git!(root, args) do
    case System.cmd("git", ["--no-optional-locks" | args], cd: root, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> fail(:workspace_mismatch)
    end
  end

  defp blob_path(store, sha), do: Path.join([store, "blobs", sha])
  defp target(destination, e), do: Path.join([destination, e["area"], e["path"]])
  defp mode?(mode), do: is_integer(mode) and mode >= 0 and mode <= 0o7777
  defp digest?(s), do: is_binary(s) and Regex.match?(~r/\A[0-9a-f]{64}\z/, s)
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp random, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  defp fail(reason), do: throw({:checkpoint_error, reason})

  defp protect(fun) do
    fun.()
  rescue
    _ in [File.Error, Jason.DecodeError, Jason.EncodeError, ArgumentError] ->
      {:error, :invalid_checkpoint}
  catch
    {:checkpoint_error, reason} -> {:error, reason}
  end
end
