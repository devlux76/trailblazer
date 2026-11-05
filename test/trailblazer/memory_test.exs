defmodule Trailblazer.MemoryTest do
  use ExUnit.Case, async: false

  alias Trailblazer.Memory
  alias Trailblazer.Loop.CaseRecord

  # Vectors from the text's words, so similar texts land near each other.
  defmodule FakeEmbed do
    def documents(docs, _opts), do: {:ok, Enum.map(docs, fn {t, x} -> vec(t <> " " <> x) end)}
    def query(text, _opts), do: {:ok, vec(text)}

    defp vec(text) do
      words = text |> String.downcase() |> String.split(~r/\W+/, trim: true) |> MapSet.new()

      for w <- ~w(multiaddr contact greeting comma failed fixed),
          do: if(w in words, do: 1.0, else: 0.0)
    end
  end

  defmodule FakeVectors do
    def ensure(_root, _opts), do: :ok

    def put(_root, points, _opts) do
      Process.put(
        :points,
        Process.get(:points, %{}) |> Map.merge(Map.new(points, &{&1.id, &1.vector}))
      )

      :ok
    end

    def nearest(_root, vector, limit, _opts) do
      hits =
        Process.get(:points, %{})
        |> Enum.map(fn {id, v} -> {id, Enum.zip_with(v, vector, &(&1 * &2)) |> Enum.sum()} end)
        |> Enum.sort_by(&(-elem(&1, 1)))
        |> Enum.take(limit)

      {:ok, hits}
    end
  end

  defmodule DownEmbed do
    def documents(_docs, _opts), do: {:error, :embedder_down}
  end

  @opts [embed: FakeEmbed, vectors: FakeVectors]

  setup do
    File.rm_rf!(Memory.root())
    on_exit(fn -> File.rm_rf!(Memory.root()) end)
    :ok
  end

  defp closed_case(request, status, check_tail, reviews \\ []) do
    {:ok, id} =
      CaseRecord.open(%{
        repo: "/r",
        request: request,
        files: ["src/core/contact.ts"],
        from: "test"
      })

    :ok = CaseRecord.event(id, :attempt, %{stage: :edit_format, format: :text})

    if check_tail,
      do: :ok = CaseRecord.event(id, :check, %{status: :fail, output_tail: check_tail})

    for v <- reviews, do: :ok = CaseRecord.event(id, :review, %{verdict: v})

    :ok =
      CaseRecord.close(id, %{
        status: status,
        summary: "#{status} summary",
        attempts: 2,
        reason: :why
      })

    id
  end

  test "an outcome holds what was asked, how it went and the first failure line" do
    id =
      closed_case(
        "Implement multiaddr validation in contact.ts",
        :failed,
        "$ tsc --noEmit\nsrc/core/contact.ts(31,22): error TS2304: Cannot find name 'multiaddr'.\nmore"
      )

    o = Memory.outcome(id, %{model: "bolt"})
    assert o.request =~ "multiaddr validation"
    assert o.status == "failed"
    assert o.edit_mode == "text"
    assert o.attempts == 2

    assert o.signature ==
             "src/core/contact.ts(31,22): error TS2304: Cannot find name 'multiaddr'."

    assert o.model == "bolt"
    assert o.files == ["src/core/contact.ts"]
  end

  test "a passing test whose name says failed is not the failure signature" do
    id =
      closed_case(
        "x",
        :failed,
        "(pass) a failed replacement keeps state [3ms]\n(fail) contact rejects junk [1ms]\n"
      )

    assert Memory.outcome(id).signature == "(fail) contact rejects junk [1ms]"
  end

  test "recorded outcomes are recalled by similarity, latest record per case" do
    a = closed_case("Implement multiaddr validation in contact", :failed, "error: x", [:fail])
    b = closed_case("Greet with a comma", :fixed, nil, [:pass])

    assert :ok = Memory.record(a, %{model: "spark"}, @opts)
    assert :ok = Memory.record(b, %{model: "bolt"}, @opts)
    assert :ok = Memory.record(a, %{model: "spark"}, @opts)
    assert length(Memory.all()) == 2

    {:ok, [{_, top} | _]} = Memory.similar("multiaddr contact check", 1, @opts)
    assert top["case"] == a
    assert top["reviews"] == ["fail"]
  end

  test "an open case or a down embedder records nothing and never raises" do
    {:ok, open} = CaseRecord.open(%{repo: "/r", request: "x"})
    assert {:error, :no_closed_case} = Memory.record(open, %{}, @opts)

    id = closed_case("Greet", :fixed, nil)

    assert {:error, :embedder_down} =
             Memory.record(id, %{}, embed: DownEmbed, vectors: FakeVectors)

    assert Memory.all() == []
  end

  test "backfill records only cases not yet in memory" do
    a = closed_case("Greet with a comma", :fixed, nil)
    b = closed_case("multiaddr contact", :failed, "error: y")
    assert :ok = Memory.record(a, %{}, @opts)
    assert Memory.backfill([a, b], @opts) == 1
    assert Enum.map(Memory.all(), & &1["case"]) |> Enum.sort() == Enum.sort([a, b])
  end
end
