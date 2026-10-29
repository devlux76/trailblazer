defmodule Trailblazer.Planner.RouteTest do
  # The pure routing check: a card is trailblazer-ready when its body names the
  # files to change and states acceptance criteria, and it is not labelled
  # dispatch:research; a card missing both is research; a card with exactly one
  # of the two is the tie the model decides.
  use ExUnit.Case, async: true
  alias Trailblazer.Planner.Route

  @body """
  Split the parser reset.

  Files: lib/parser.ex, test/parser_test.exs
  Acceptance: make test passes with the reset helper added
  Implementation plan: 1. Extract reset in lib/parser.ex; 2. Test the reset helper.
  """

  test "a labelled research card stays research even with full markers" do
    assert Route.classify(%{"labels" => ["dispatch:ready", "dispatch:research"], "body" => @body}) ==
             :research
  end

  test "named files plus acceptance criteria is trailblazer" do
    assert Route.classify(%{"labels" => ["dispatch:ready"], "body" => @body}) == :trailblazer
  end

  test "files and acceptance without an implementation plan need research" do
    assert Route.classify(%{"body" => "Files: lib/a.ex\nAcceptance: make test"}) == :research
    assert Route.classify(%{"body" => "Files: lib/a.ex\nAcceptance: make test\nImplementation plan:   "}) == :research
  end

  test "files without acceptance is the model's tie" do
    assert Route.classify(%{"labels" => [], "body" => "Files: lib/a.ex\nImplementation plan: Change a.ex and test the reset."}) == :tie
  end

  test "acceptance without files is the model's tie" do
    assert Route.classify(%{"labels" => [], "body" => "Acceptance: make test\nImplementation plan: Change a.ex and test the reset."}) == :tie
  end

  test "a body with neither marker is research" do
    assert Route.classify(%{"labels" => [], "body" => "please look into this"}) == :research
  end

  test "a context without bodies or labels cannot be trailblazer" do
    assert Route.classify(%{}) == :research
    assert Route.classify(%{"labels" => nil, "body" => nil}) == :research
  end

  test "an empty files list is no files" do
    assert Route.classify(%{"labels" => [], "body" => "Files:  \nAcceptance: make test\nImplementation plan: Change a.ex and test reset."}) == :tie
  end

  test "the first markers of each kind win" do
    body = "Acceptance: first\nFiles: lib/a.ex\nAcceptance: second"

    assert {:ok, ["lib/a.ex"]} = Route.parse_files(body)
    assert {:ok, "first"} = Route.parse_acceptance(body)
  end

  test "files are comma or space separated repo-relative paths" do
    assert {:ok, ["lib/a.ex", "test/a_test.exs", "mix.exs"]} =
             Route.parse_files("Files: lib/a.ex, test/a_test.exs mix.exs")
  end

  test "absolute paths and traversal are refused" do
    assert :error = Route.parse_files("Files: /etc/passwd")
    assert :error = Route.parse_files("Files: ../escape.ex")
    assert :error = Route.parse_files("Files: lib/a.ex and ..")
  end

  test "a Files line without a path is no files" do
    assert :error = Route.parse_files(".Files: nope")
    assert :error = Route.parse_files("Files:")
  end

  test "only a line that starts with the marker counts" do
    assert :error = Route.parse_files("see Files: lib/a.ex")
    assert {:ok, ["lib/a.ex"]} = Route.parse_files("x\nFiles: lib/a.ex")
  end

  test "a multiline file value ends at the line" do
    assert {:ok, ["lib/a.ex"]} = Route.parse_files("Files: lib/a.ex\nmore text")
  end

  test "acceptance needs content on its line" do
    assert {:ok, "make test passes"} = Route.parse_acceptance("Acceptance: make test passes")
    assert :error = Route.parse_acceptance("Acceptance:")
    assert :error = Route.parse_acceptance("Acceptance:   ")
  end
end
