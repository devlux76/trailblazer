defmodule Trailblazer.ModelTest do
  use ExUnit.Case, async: true
  alias Trailblazer.Model

  defp options(name), do: [req_options: [plug: {Req.Test, name}]]

  defp event(delta, finish \\ nil),
    do: %{choices: [%{index: 0, delta: delta, finish_reason: finish}]}

  defp stream(conn, events, done? \\ true) do
    text =
      Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\r\n\r\n")) <>
        if(done?, do: "data: [DONE]\r\n\r\n", else: "")

    conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_resp(200, text)
  end

  test "per-role sampling overrides temperature, top_p, top_k and thinking" do
    Req.Test.stub(:model_sampling, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      assert body["temperature"] == 0.6
      assert body["top_p"] == 0.9
      assert body["top_k"] == 20
      assert body["chat_template_kwargs"]["enable_thinking"] == false
      stream(conn, [event(%{content: "ok"}, "stop")])
    end)

    sampling = %{temperature: 0.6, top_p: 0.9, top_k: 20, thinking: false}

    assert {:ok, %{content: "ok"}} =
             Model.chat(
               [%{role: "user", content: "hi"}],
               options(:model_sampling) ++ [sampling: sampling]
             )
  end

  test "streamed reasoning stays separate and settings match the plan" do
    Req.Test.stub(:model_happy, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      assert body["model"] == "spark-x2.6-4b:q8-dspark"
      assert body["temperature"] == 1.0
      assert body["top_p"] == 0.95
      assert body["top_k"] == 0
      assert body["min_p"] == 0
      assert body["presence_penalty"] == 0
      assert body["frequency_penalty"] == 0
      assert body["repeat_penalty"] == 1.0

      assert body["chat_template_kwargs"] == %{
               "enable_thinking" => true,
               "reasoning_effort" => "high"
             }

      assert body["stream"] == true
      assert body["max_tokens"] == 16_384
      refute Map.has_key?(body, "reasoning_budget_tokens")
      assert body["messages"] == [%{"role" => "assistant", "content" => "prior"}]
      assert body["tools"] == [%{"type" => "function"}]

      stream(conn, [
        event(%{reasoning_content: "think"}),
        event(%{content: "hello "}),
        event(%{content: "world"}, "stop"),
        %{choices: [], usage: %{prompt_tokens: 7, completion_tokens: 3}}
      ])
    end)

    assert {:ok, reply} =
             Model.chat(
               [%{role: "assistant", content: "prior", reasoning_content: "secret"}],
               options(:model_happy) ++ [tools: [%{type: "function"}]]
             )

    assert reply.content == "hello world"
    assert reply.reasoning == "think"
    assert reply.tool_calls == []
    assert reply.usage == %{prompt_tokens: 7, completion_tokens: 3}
    assert reply.ms >= 0
    assert is_integer(reply.first_token_ms)
  end

  test "tool call ids, names and JSON arguments assemble across deltas" do
    Req.Test.stub(:model_tools, fn conn ->
      stream(conn, [
        event(%{
          tool_calls: [
            %{index: 0, id: "call_1", function: %{name: "re", arguments: "{\"path\":"}}
          ]
        }),
        event(
          %{tool_calls: [%{index: 0, function: %{name: "ad", arguments: "\"a.ex\"}"}}]},
          "tool_calls"
        )
      ])
    end)

    assert {:ok, %{tool_calls: [%{id: "call_1", name: "read", arguments: args}]}} =
             Model.chat([], options(:model_tools))

    assert Jason.decode!(args) == %{"path" => "a.ex"}
  end

  test "cut streams, empty choices, bad deltas and invalid bytes are errors" do
    for {name, events, done?} <- [
          {:model_cut, [event(%{content: "partial"}, "stop")], false},
          {:model_empty, [%{choices: []}], true},
          {:model_bad_delta, [%{choices: [123]}], true},
          {:model_no_finish, [event(%{content: "partial"})], true}
        ] do
      Req.Test.stub(name, fn conn -> stream(conn, events, done?) end)
      assert {:error, {:bad_response, _}} = Model.chat([], options(name))
    end

    Req.Test.stub(:model_invalid, fn conn ->
      Plug.Conn.send_resp(conn, 200, <<"data: ", 255, "\n\n">>)
    end)

    assert {:error, {:bad_response, _}} = Model.chat([], options(:model_invalid))
  end

  test "transport, timeout and HTTP errors have defined shapes" do
    Req.Test.stub(:model_down, &Req.Test.transport_error(&1, :econnrefused))
    Req.Test.stub(:model_timeout, &Req.Test.transport_error(&1, :timeout))
    Req.Test.stub(:model_http, &Plug.Conn.send_resp(&1, 500, "down"))
    assert {:error, :model_down} = Model.chat([], options(:model_down))
    assert {:error, :timeout} = Model.chat([], options(:model_timeout))
    assert {:error, {:http, 500}} = Model.chat([], options(:model_http))
  end

  test "loading responses wait and retry within the timeout" do
    {:ok, count} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(:model_loading, fn conn ->
      if Agent.get_and_update(count, &{&1, &1 + 1}) == 0,
        do: Plug.Conn.send_resp(conn, 503, "Loading model"),
        else: stream(conn, [event(%{content: "ready"}, "stop")])
    end)

    assert {:ok, %{content: "ready"}} = Model.chat([], options(:model_loading))
  end

  test "copied SSE parser handles byte splits and native tool calls stay data" do
    parser = Trailblazer.Model.SSEParser.new()

    bytes =
      "data: " <> Jason.encode!(event(%{content: "🙂"}, "stop")) <> "\r\n\r\ndata: [DONE]\r\n\r\n"

    {frames, _} =
      for <<byte <- bytes>>, reduce: {[], parser} do
        {frames, parser} ->
          {next, parser} = Trailblazer.Model.SSEParser.feed(parser, <<byte>>)
          {frames ++ next, parser}
      end

    assert [{:data, json}, :done] = frames
    assert Jason.decode!(json)["choices"] |> hd() |> get_in(["delta", "content"]) == "🙂"

    Req.Test.stub(:model_native, fn conn ->
      text = ~s'<|tool_call_start|>[read(path="a,b.ex", line=2)]<|tool_call_end|>'
      stream(conn, [event(%{content: text}, "stop")])
    end)

    assert {:ok, %{content: "", tool_calls: [%{name: "read", arguments: args}]}} =
             Model.chat([], options(:model_native))

    assert Jason.decode!(args) == %{"path" => "a,b.ex", "line" => 2}
  end

  # One chunk, then a stream that never goes on: only the backstop ends it.
  defmodule GenerationAdapter do
    def run(req, observer \\ nil) do
      response = Req.Response.new(status: 200)

      first =
        "data: " <>
          Jason.encode!(%{
            choices: [%{delta: %{reasoning_content: "thinking", content: "partial"}}]
          }) <> "\n\n"

      {:cont, pair} = req.into.({:data, first}, {req, response})
      if observer, do: send(observer, :prefix_parsed)

      receive do
        :never -> pair
      end
    end
  end

  # B4 (design §13.2): the first-token and total deadlines became one
  # backstop per call; a backstop that fires is an anomaly.
  test "a backstop stops a stalled stream, keeps its prefix once, and is an anomaly" do
    parent = self()
    :ok = Trailblazer.Events.subscribe(:anomaly)

    trigger =
      Task.async(fn ->
        :ok = Trailblazer.Events.subscribe(:backstop)
        send(parent, :backstop_observer_ready)

        receive do
          {:trailblazer_event, :backstop, {:armed, ref, :model_call, _, _}} ->
            receive do
              :prefix_parsed -> send(Trailblazer.Backstop, {:fire, ref})
            end
        end
      end)

    on_exit(fn -> Process.exit(trigger.pid, :kill) end)
    assert_receive :backstop_observer_ready, 5000

    assert {:error, {:backstop, id}} =
             Model.chat([],
               backstop_ms: 60_000,
               on_partial: fn reply -> send(parent, {:partial, reply}) end,
               req_options: [adapter: fn req -> GenerationAdapter.run(req, trigger.pid) end]
             )

    Task.await(trigger, :infinity)
    assert is_integer(id)
    assert_receive {:partial, %{content: "partial", reasoning: "thinking"}}
    refute_received {:partial, _}

    # every model-call backstop is one open anomaly until acknowledged (J6),
    # so this report's own evidence is the one published with it
    assert_receive {:trailblazer_event, :anomaly,
                    %{id: ^id, kind: "model_call", evidence: %{content_bytes: 7} = evidence}}

    assert evidence.reasoning_bytes == 8
    assert evidence.limit_ms == 60_000
  end

  test "a backstop also stops a call that never answers at all" do
    Req.Test.stub(:model_never, fn conn ->
      receive do
        :never -> conn
      end
    end)

    assert {:error, {:backstop, _id}} =
             Model.chat([], options(:model_never) ++ [backstop_ms: 50])
  end

  test "stop_when ends an endless stream as a finished reply with what it had" do
    Req.Test.stub(:model_stop, fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      Enum.reduce(["one ", "loop ", "after"], conn, fn text, conn ->
        {:ok, conn} =
          Plug.Conn.chunk(conn, "data: " <> Jason.encode!(event(%{content: text})) <> "\r\n\r\n")

        conn
      end)
    end)

    stop = &String.contains?(&1, "loop")

    assert {:ok, %{content: "one loop ", finish_reason: "host_stop"}} =
             Model.chat([], options(:model_stop) ++ [stop_when: stop])
  end

  test "on_delta is handed each chunk's reasoning and content as they stream" do
    Req.Test.stub(:model_delta, fn conn ->
      stream(conn, [
        event(%{reasoning_content: "think "}),
        event(%{reasoning_content: "more"}),
        event(%{content: "hello"}, "stop")
      ])
    end)

    me = self()
    on_delta = fn delta -> send(me, {:delta, delta}) end

    assert {:ok, %{content: "hello"}} =
             Model.chat([], options(:model_delta) ++ [on_delta: on_delta])

    deltas = collect_deltas([])
    assert Enum.map_join(deltas, & &1.reasoning) == "think more"
    assert Enum.map_join(deltas, & &1.content) == "hello"
    assert Enum.all?(deltas, &(&1.reasoning != "" or &1.content != ""))
  end

  # L9 T1: eleven minutes reading a 7k-token prompt showed nothing at all.
  test "on_progress is handed the server's prompt progress before any token" do
    Req.Test.stub(:model_progress, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["return_progress"] == true

      stream(conn, [
        %{choices: [], prompt_progress: %{total: 7000, cache: 400, processed: 0, time_ms: 0}},
        %{
          choices: [],
          prompt_progress: %{total: 7000, cache: 400, processed: 512, time_ms: 56_000}
        },
        event(%{content: "ok"}, "stop")
      ])
    end)

    me = self()
    on_progress = fn p -> send(me, {:progress, p}) end

    assert {:ok, %{content: "ok"}} =
             Model.chat([], options(:model_progress) ++ [on_progress: on_progress])

    assert_received {:progress, %{total: 7000, cache: 400, processed: 0}}
    assert_received {:progress, %{total: 7000, processed: 512, ms: 56_000}}
  end

  defp collect_deltas(acc) do
    receive do
      {:delta, delta} -> collect_deltas([delta | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "finish reason is returned for length-cutoff feedback" do
    Req.Test.stub(:model_length, fn conn -> stream(conn, [event(%{content: "cut"}, "length")]) end)

    assert {:ok, %{finish_reason: "length"}} = Model.chat([], options(:model_length))
  end

  test "reasoning-only length exhaustion preserves evidence and has an explicit outcome" do
    Req.Test.stub(:reasoning_length, fn conn ->
      stream(conn, [event(%{reasoning_content: "unfinished plan"}, "length")])
    end)

    parent = self()

    assert {:error, :output_limit} =
             Model.chat(
               [],
               options(:reasoning_length) ++
                 [on_partial: fn reply -> send(parent, {:partial_limit, reply}) end]
             )

    assert_receive {:partial_limit,
                    %{reasoning: "unfinished plan", content: "", finish_reason: "length"}}
  end

  test "explicit thinking budget reserves answer space while retaining high effort" do
    Req.Test.stub(:thinking_budget, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      assert body["reasoning_budget_tokens"] == 1024
      assert body["max_tokens"] == 4096

      assert body["chat_template_kwargs"] == %{
               "enable_thinking" => true,
               "reasoning_effort" => "high"
             }

      stream(conn, [event(%{content: "answer"}, "stop")])
    end)

    assert {:ok, _} =
             Model.chat(
               [],
               options(:thinking_budget) ++
                 [reasoning_budget_tokens: 1024, max_tokens: 4096]
             )
  end

  test "invalid thinking budgets fail before any HTTP request" do
    Req.Test.stub(:invalid_thinking_budget, fn _ -> raise "invalid budget reached HTTP" end)

    for invalid <- [-1, 4096, 4097, true, false, "1024", 1.5] do
      assert_raise ArgumentError, ~r/reasoning_budget_tokens/, fn ->
        Model.chat(
          [],
          options(:invalid_thinking_budget) ++
            [reasoning_budget_tokens: invalid, max_tokens: 4096]
        )
      end
    end
  end

  test "a client exception stays catchable by the calling loop" do
    Req.Test.stub(:model_raises, fn _ -> raise "broken client" end)
    assert_raise RuntimeError, "broken client", fn -> Model.chat([], options(:model_raises)) end
  end

  test "a complete SSE frame is emitted even if the next frame is partial" do
    json = Jason.encode!(event(%{content: "prefix"}))

    {frames, parser} =
      Trailblazer.Model.SSEParser.feed(
        Trailblazer.Model.SSEParser.new(),
        "data: " <> json <> "\n\ndata: {"
      )

    assert frames == [{:data, json}]
    assert parser.input_buffer == "data: {"
  end

  test "native edit tool choice and explicit reasoning effort reach the server" do
    Req.Test.stub(:model_edit_choice, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)

      assert body["tool_choice"] == %{
               "type" => "function",
               "function" => %{"name" => "submit_edits"}
             }

      assert body["chat_template_kwargs"]["reasoning_effort"] == "low"
      assert body["max_tokens"] == 512
      stream(conn, [event(%{content: "done"}, "stop")])
    end)

    assert {:ok, _} =
             Model.chat(
               [],
               options(:model_edit_choice) ++
                 [
                   tools: [Trailblazer.Loop.Tools.edit_definition()],
                   tool_choice: %{type: "function", function: %{name: "submit_edits"}},
                   reasoning_effort: "low",
                   max_tokens: 512
                 ]
             )
  end

  test "llama-server timings in the final chunk reach the reply" do
    timings = %{
      "prompt_n" => 14,
      "cache_n" => 2834,
      "prompt_ms" => 841.2,
      "predicted_n" => 1,
      "predicted_ms" => 3.1,
      "draft_n" => 9
    }

    Req.Test.stub(:model_timings, fn conn ->
      stream(conn, [
        event(%{content: "ok"}, "stop"),
        %{choices: [], timings: timings}
      ])
    end)

    assert {:ok, reply} = Model.chat([%{role: "user", content: "hi"}], options(:model_timings))

    assert reply.timings == %{
             prompt_n: 14,
             cache_n: 2834,
             prompt_ms: 841.2,
             predicted_n: 1,
             predicted_ms: 3.1
           }
  end

  test "a stream without timings replies with timings nil" do
    Req.Test.stub(:model_no_timings, fn conn ->
      stream(conn, [event(%{content: "ok"}, "stop")])
    end)

    assert {:ok, %{timings: nil}} =
             Model.chat([%{role: "user", content: "hi"}], options(:model_no_timings))
  end

  @tag :live
  test "one router call" do
    assert {:ok, reply} = Model.chat([%{role: "user", content: "Reply with OK."}], [])
    assert reply.content != ""
  end
end
