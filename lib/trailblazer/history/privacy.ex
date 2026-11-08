defmodule Trailblazer.History.Privacy do
  @moduledoc "The history's privacy screen: the home directory written as ~, the commit hook's patterns, and the fields a privacy match drops an entry for."

  @doc false
  def tilde(text, home), do: String.replace(text, home, "~")

  @screened [:request, :message, :path, :patch]

  @doc false
  def screen(fields, patterns) do
    cond do
      field = Enum.find(@screened, &(not String.valid?(fields[&1]))) ->
        {:drop, "#{field} not utf-8"}

      field = Enum.find(@screened, fn f -> Enum.any?(patterns, &Regex.match?(&1, fields[f])) end) ->
        {:drop, field}

      true ->
        :ok
    end
  end

  # The commit hook's patterns, case-insensitive as the hooks apply them;
  # never printed, logged or copied. Missing, empty or uncompilable refuses.
  @doc false
  def patterns(opts) do
    path = Keyword.get_lazy(opts, :pii_file, fn -> Path.expand("~/.config/git/pii-patterns") end)

    with {:ok, text} <- File.read(path),
         lines =
           for(
             line <- String.split(text, "\n"),
             line = String.trim(line),
             line != "" and not String.starts_with?(line, "#"),
             do: line
           ),
         true <- lines != [],
         compiled = Enum.map(lines, &Regex.compile(&1, "i")),
         true <- Enum.all?(compiled, &match?({:ok, _}, &1)) do
      {:ok, Enum.map(compiled, fn {:ok, re} -> re end)}
    else
      _ -> {:error, :pii_patterns}
    end
  end
end
