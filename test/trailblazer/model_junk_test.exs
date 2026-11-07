defmodule Trailblazer.ModelJunkTest do
  use ExUnit.Case, async: true
  alias Trailblazer.Model

  defp options(name), do: [req_options: [plug: {Req.Test, name}]]

  defp reply(conn, content) do
    event = %{choices: [%{index: 0, delta: %{content: content}, finish_reason: "stop"}]}
    text = "data: " <> Jason.encode!(event) <> "\r\n\r\ndata: [DONE]\r\n\r\n"
    conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_resp(200, text)
  end

  @junk "<tool_call>think_effort<arg_key>thinking_effort</arg_key><arg_value>high</arg_value></tool_call>"

  test "the live junk shapes are recognised; real answers are not" do
    assert Model.junk_reply?(@junk)
    assert Model.junk_reply?("<tool_call>think_effort=high</tool_call>\n")
    refute Model.junk_reply?("<tool_call>\n<edit path=\"a\" start=\"1\" end=\"1\">")
    refute Model.junk_reply?("src/a.ts\n```ts\nx\n```")
    refute Model.junk_reply?(nil)
  end

  test "a junk-only reply with no tools offered is asked again once" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(:model_junk, fn conn ->
      n = Agent.get_and_update(calls, &{&1, &1 + 1})
      reply(conn, if(n == 0, do: @junk, else: "fixed"))
    end)

    assert {:ok, %{content: "fixed"}} = Model.chat([%{role: "user", content: "hi"}], options(:model_junk))
    assert Agent.get(calls, & &1) == 2
  end

  test "junk twice is returned as is (one re-ask only)" do
    Req.Test.stub(:model_junk2, fn conn -> reply(conn, @junk) end)
    assert {:ok, %{content: @junk}} = Model.chat([%{role: "user", content: "hi"}], options(:model_junk2))
  end
end
