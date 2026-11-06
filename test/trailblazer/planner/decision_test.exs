defmodule Trailblazer.Planner.DecisionTest do
  # The advisory selection call: a strict, pure validator plus one bounded
  # non-streaming request to the existing local model. The model is never
  # called here; the HTTP boundary is injected.
  use ExUnit.Case, async: false
  alias Trailblazer.Planner.Decision

  @cards [
    %{
      ref: "probe:aaaa11",
      check: "make check",
      context: %{"ref" => "probe:aaaa11", "title" => "first"}
    },
    %{
      ref: "probe:bbbb22",
      check: "bun test",
      context: %{"ref" => "probe:bbbb22", "title" => "second"}
    }
  ]

  defp reply(content, finish_reason \\ "stop") do
    {:ok,
     %{
       status: 200,
       body: %{
         "choices" => [
           %{"finish_reason" => finish_reason, "message" => %{"content" => content}}
         ]
       }
     }}
  end

  describe "validate/2 (pure)" do
    test "accepts a listed ref with the trailblazer target and a short reason" do
      raw = ~s({"ref": "probe:aaaa11", "target": "trailblazer", "reason": "unblocks the rest"})

      assert {:ok, %{ref: "probe:aaaa11", target: "trailblazer", reason: "unblocks the rest"}} =
               Decision.validate(raw, @cards)
    end

    test "accepts an explicit wait" do
      raw = ~s({"ref": null, "target": null, "reason": "nothing worth dispatching"})
      assert {:ok, :wait} = Decision.validate(raw, @cards)
    end

    test "accepts a research target for a listed ref" do
      raw = ~s({"ref": "probe:bbbb22", "target": "research", "reason": "needs a plan"})

      assert {:ok, %{ref: "probe:bbbb22", target: "research", reason: "needs a plan"}} =
               Decision.validate(raw, @cards)
    end

    test "rejects unknown keys" do
      raw = ~s({"ref": "probe:aaaa11", "target": "trailblazer", "reason": "r", "cmd": "rm -rf /"})
      assert {:error, :bad_decision} = Decision.validate(raw, @cards)
    end

    test "rejects a ref that was not listed" do
      raw = ~s({"ref": "forge:fffff", "target": "trailblazer", "reason": "r"})
      assert {:error, :unknown_ref} = Decision.validate(raw, @cards)
    end

    test "rejects a foreign target" do
      raw = ~s({"ref": "probe:aaaa11", "target": "codex", "reason": "r"})
      assert {:error, :bad_decision} = Decision.validate(raw, @cards)
    end

    test "rejects a selection without the trailblazer target" do
      raw = ~s({"ref": "probe:aaaa11", "target": null, "reason": "r"})
      assert {:error, :bad_decision} = Decision.validate(raw, @cards)
    end

    test "rejects a wait that names a target" do
      raw = ~s({"ref": null, "target": "trailblazer", "reason": "r"})
      assert {:error, :bad_decision} = Decision.validate(raw, @cards)
    end

    test "rejects missing keys, non-JSON and non-object replies" do
      assert {:error, :bad_decision} = Decision.validate(~s({"ref": "probe:aaaa11"}), @cards)
      assert {:error, :bad_json} = Decision.validate("not json at all", @cards)
      assert {:error, :bad_decision} = Decision.validate(~s([1,2,3]), @cards)

      assert {:error, :bad_json} =
               Decision.validate(~s(```json\n{"ref": null}\n```), @cards)
    end

    test "rejects oversized replies and reasons" do
      raw = ~s({"ref": null, "target": null, "reason": "#{String.duplicate("x", 1500)}"})
      assert {:error, :oversized_reason} = Decision.validate(raw, @cards)

      huge = ~s({"ref": null, "target": null, "reason": "#{String.duplicate("x", 9000)}"})
      assert {:error, :oversized} = Decision.validate(huge, @cards)
    end

    test "rejects a non-string reason" do
      assert {:error, :bad_decision} =
               Decision.validate(~s({"ref": null, "target": null, "reason": 7}), @cards)
    end
  end

  describe "choose/2 (injected HTTP)" do
    test "posts a bounded non-streaming request to the configured local model and validates the reply" do
      parent = self()

      post = fn url, body ->
        send(parent, {:posted, url, body})
        reply(~s({"ref": "probe:bbbb22", "target": "trailblazer", "reason": "next in line"}))
      end

      assert {:ok, %{ref: "probe:bbbb22"}} = Decision.choose(@cards, post: post)

      assert_receive {:posted, url, body}
      assert String.ends_with?(url, "/chat/completions")
      assert String.starts_with?(url, "http://127.0.0.1")
      assert String.starts_with?(url, Trailblazer.Config.get(:planner_model_url))
      assert body.model == Trailblazer.Config.get(:planner_model)
      assert body.max_tokens == 384
      assert body.temperature == 0
      assert body.stream == false
      assert body.response_format["type"] == "json_schema"

      assert %{"target" => %{"enum" => ["trailblazer", nil, "research"]}} =
               body.response_format["json_schema"]["schema"]["properties"]

      assert body.chat_template_kwargs == %{preserve_thinking: false, enable_thinking: false}
      assert [%{role: "system"}, %{role: "user", content: user}] = body.messages
      assert user =~ ~s("ref":"probe:aaaa11")
    end

    test "with planner_prefill: renders by the server's template, appends the prefill, posts the raw completion with the schema" do
      Application.put_env(:trailblazer, :planner_prefill, "</think>")
      on_exit(fn -> Application.delete_env(:trailblazer, :planner_prefill) end)
      parent = self()

      post = fn url, body ->
        send(parent, {:posted, url, body})

        if String.ends_with?(url, "/apply-template"),
          do: {:ok, %{status: 200, body: %{"prompt" => "RENDERED<think>"}}},
          else:
            {:ok,
             %{
               status: 200,
               body: %{
                 "content" =>
                   ~s({"ref": "probe:aaaa11", "target": "trailblazer", "reason": "first"}),
                 "stop_type" => "eos"
               }
             }}
      end

      assert {:ok, %{ref: "probe:aaaa11", target: "trailblazer"}} =
               Decision.choose(@cards, post: post)

      root = String.replace_suffix(Trailblazer.Config.get(:planner_model_url), "/v1", "")
      assert_receive {:posted, url1, %{messages: [%{role: "system"}, %{role: "user"}]}}
      assert url1 == root <> "/apply-template"
      assert_receive {:posted, url2, body}
      assert url2 == root <> "/completion"
      assert body.prompt == "RENDERED<think></think>"
      assert body.n_predict == 384
      assert body.temperature == 0
      assert body.json_schema["properties"]["target"]["enum"] == ["trailblazer", nil, "research"]
    end

    test "with planner_prefill: a completion cut at the token limit is an error, and a failed render posts nothing more" do
      Application.put_env(:trailblazer, :planner_prefill, "</think>")
      on_exit(fn -> Application.delete_env(:trailblazer, :planner_prefill) end)

      cut = fn url, _ ->
        if String.ends_with?(url, "/apply-template"),
          do: {:ok, %{status: 200, body: %{"prompt" => "P"}}},
          else:
            {:ok, %{status: 200, body: %{"content" => ~s({"ref": "pro), "stop_type" => "limit"}}}
      end

      assert {:error, {:completion, "limit"}} = Decision.choose(@cards, post: cut)

      failed = fn url, _ ->
        if String.ends_with?(url, "/apply-template"),
          do: {:ok, %{status: 500}},
          else: flunk("must not complete without a rendered prompt")
      end

      assert {:error, {:http, 500}} = Decision.choose(@cards, post: failed)
    end

    test "refuses a non-loopback model URL without calling anything" do
      Application.put_env(:trailblazer, :planner_model_url, "http://10.1.2.3:8098/v1")

      on_exit(fn -> Application.delete_env(:trailblazer, :planner_model_url) end)

      assert {:error, :not_loopback} =
               Decision.choose(@cards, post: fn _url, _body -> flunk("must not post") end)
    end

    test "a truncated completion is an error, never a decision" do
      post = fn _url, _body -> reply("{}", "length") end
      assert {:error, {:completion, "length"}} = Decision.choose(@cards, post: post)
    end

    test "an HTTP failure and a transport failure are errors" do
      assert {:error, {:http, 500}} =
               Decision.choose(@cards, post: fn _u, _b -> {:ok, %{status: 500, body: "x"}} end)

      assert {:error, {:http_error, :econnrefused}} =
               Decision.choose(@cards, post: fn _u, _b -> {:error, :econnrefused} end)
    end

    test "a garbage reply body is an error" do
      assert {:error, :bad_completion} =
               Decision.choose(@cards,
                 post: fn _u, _b -> {:ok, %{status: 200, body: "plain"}} end
               )
    end

    test "the call is bounded by the Backstop, not by an HTTP timeout" do
      post = fn _url, _body ->
        Process.sleep(5_000)
        reply(~s({"ref": null, "target": null, "reason": "late"}))
      end

      assert {:error, {:backstop, _id}} = Decision.choose(@cards, post: post, limit_ms: 50)
    end
  end
end
