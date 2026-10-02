defmodule C3.WatchScriptTest do
  @moduledoc """
  The watcher script of the plugin (`plugin/skills/c3/scripts/c3-watch.sh`) against a real
  HTTP listener: it exits on a request for its agent, ignores the others', survives the
  server being unreachable, and stops when the session closes (spec, *Testing › Watcher*).
  """
  use C3Web.ConnCase

  @moduletag :watcher

  @script Path.expand("../../plugin/skills/c3/scripts/c3-watch.sh", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "c3-watch-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{state_dir: dir, port: free_port()}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp serve(port) do
    start_supervised!(
      {Bandit, plug: C3Web.Endpoint, ip: {127, 0, 0, 1}, port: port, startup_log: false}
    )
  end

  defp fresh_conn, do: with_ip(build_conn(), unique_ip())

  defp authed(token), do: put_req_header(fresh_conn(), "authorization", "Bearer " <> token)

  # AG1, AG2 and AG3 in a new session: %{code, t1, t2, t3}.
  defp session! do
    created = fresh_conn() |> post(~p"/v1/sessions", %{}) |> json_response(201)
    %{"session_code" => code, "secret" => secret, "agent" => %{"token" => t1}} = created

    join = fn ->
      fresh_conn()
      |> post(~p"/v1/sessions/#{code}/join", %{"secret" => secret})
      |> json_response(201)
      |> get_in(["agent", "token"])
    end

    %{code: code, t1: t1, t2: join.(), t3: join.()}
  end

  defp open_thread(s, to, title) do
    authed(s.t1)
    |> post(~p"/v1/sessions/#{s.code}/threads", %{"title" => title, "body" => "?", "to" => to})
    |> json_response(201)
  end

  defp env(ctx, extra) do
    [
      {"C3_STATE_DIR", ctx.state_dir},
      {"C3_WATCH_POLL", "2"},
      {"C3_WATCH_RETRY", "1"},
      {"C3_WATCH_MAX_SECONDS", "20"}
      | extra
    ]
  end

  defp save!(ctx, s, name, token) do
    {out, 0} =
      System.cmd(
        "sh",
        ["-c", ~s(printf '%s\\n' "$T" | sh "$0" save "$1" "$2" "$3"), @script] ++
          ["http://127.0.0.1:#{ctx.port}/", s.code, name],
        env: env(ctx, [{"T", token}])
      )

    String.trim(out)
  end

  defp wait_async(ctx, key, extra \\ []) do
    Task.async(fn -> System.cmd("sh", [@script, "wait", key], env: env(ctx, extra)) end)
  end

  defp state(ctx, key), do: File.read!(Path.join(ctx.state_dir, key))

  test "exits on a request for its agent and ignores the others'", ctx do
    serve(ctx.port)
    s = session!()
    key = save!(ctx, s, "AG3", s.t3)
    assert key == "#{s.code}-AG3"
    # The cursor starts at the session's end (the three joins), not at 0.
    assert state(ctx, key) =~ "after=3\n"

    task = wait_async(ctx, key)
    Process.sleep(300)
    open_thread(s, ["AG2"], "Not yours")
    Process.sleep(300)
    open_thread(s, ["AG3"], "Yours")

    {out, 0} = Task.await(task, 15_000)

    assert [
             "c3 " <> header,
             "request " <> request,
             "relaunch: sh " <> relaunch
           ] = String.split(out, "\n", trim: true)

    assert header == "#{s.code} AG3"
    assert request =~ ~r/T2\.1 from AG1 "Yours"$/
    refute out =~ "Not yours"
    assert relaunch =~ ~r/c3-watch\.sh" wait #{key}$/

    [_, seq] = Regex.run(~r/^(\d+) /, request)
    assert state(ctx, key) =~ "after=#{seq}\n"
    refute state(ctx, key) =~ "Bearer"
  end

  test "survives the server being unreachable, and picks up from its cursor", ctx do
    s = session!()
    key = save!(ctx, s, "AG2", s.t2)

    task = wait_async(ctx, key)
    Process.sleep(1_500)
    serve(ctx.port)
    open_thread(s, ["AG2"], "After the cut")

    {out, 0} = Task.await(task, 15_000)
    assert out =~ ~r/^request \d+ T1\.1 from AG1 "After the cut"$/m
  end

  test "a closed session is a stop line, and no relaunch", ctx do
    serve(ctx.port)
    s = session!()
    key = save!(ctx, s, "AG2", s.t2)

    task = wait_async(ctx, key)
    Process.sleep(300)
    authed(s.t1) |> post(~p"/v1/sessions/#{s.code}/close", %{}) |> json_response(200)

    {out, 0} = Task.await(task, 15_000)
    assert out =~ ~r/^stop \d+ session_closed by AG1 reason manual$/m
    refute out =~ "relaunch"

    # Relaunched anyway, it stops at once on the 410.
    {out, 0} = System.cmd("sh", [@script, "wait", key], env: env(ctx, []))
    assert out =~ ~r/^stop http_410 /m
    refute out =~ "relaunch"
  end

  test "without news it exits with an idle line and the relaunch", ctx do
    serve(ctx.port)
    s = session!()
    key = save!(ctx, s, "AG2", s.t2)

    {out, 0} =
      System.cmd("sh", [@script, "wait", key],
        env: env(ctx, [{"C3_WATCH_MAX_SECONDS", "1"}, {"C3_WATCH_POLL", "1"}])
      )

    assert out =~ ~r/^idle no news for 1 s$/m
    assert out =~ ~r/^relaunch: sh .* wait #{key}$/m
    assert state(ctx, key) =~ ~r/after=[1-9]/
  end

  test "after save, the backlog is the inbox's: the watcher only reports what comes next", ctx do
    serve(ctx.port)
    s = session!()
    open_thread(s, ["AG2"], "Already waiting")
    key = save!(ctx, s, "AG2", s.t2)

    task = wait_async(ctx, key)
    Process.sleep(300)
    open_thread(s, ["AG2"], "New")

    {out, 0} = Task.await(task, 15_000)
    assert out =~ ~r/^request \d+ T2\.1 from AG1 "New"$/m
    refute out =~ "Already waiting"
  end

  test "save keeps the cursor for the same token, list never shows it", ctx do
    s = session!()
    key = save!(ctx, s, "AG2", s.t2)
    path = Path.join(ctx.state_dir, key)
    File.write!(path, String.replace(File.read!(path), "after=0", "after=7"))

    assert save!(ctx, s, "AG2", s.t2) == key
    assert state(ctx, key) =~ "after=7\n"

    {out, 0} = System.cmd("sh", [@script, "list"], env: env(ctx, []))
    assert out =~ "#{key} url=http://127.0.0.1:#{ctx.port} after=7"
    refute out =~ s.t2

    {_, 0} = System.cmd("sh", [@script, "forget", key], env: env(ctx, []))
    refute File.exists?(path)
  end
end
