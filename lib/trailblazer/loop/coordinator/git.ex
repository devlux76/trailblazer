defmodule Trailblazer.Loop.Coordinator.Git do
  @moduledoc "Git plumbing for the coordinator: commands run with hooks off, and the ancestry check."

  @doc false
  def ancestor?(repo, a, b), do: match?({_, 0}, cmd(repo, ["merge-base", "--is-ancestor", a, b]))

  @doc false
  def cmd(repo, args) do
    System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args,
      cd: repo,
      stderr_to_stdout: true
    )
  rescue
    e in ErlangError -> {Exception.message(e), 128}
  end

  @doc false
  def git_raw(repo, args) do
    case System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args, cd: repo) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {code, String.slice(out, -400, 400)}}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end

  @doc false
  def git(repo, args) do
    case System.cmd("git", ["-c", "core.hooksPath=/dev/null"] ++ args,
           cd: repo,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim_trailing(out, "\n")}
      {out, _} -> {:error, String.trim(out)}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end
end
