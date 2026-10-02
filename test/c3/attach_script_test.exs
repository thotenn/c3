defmodule C3.AttachScriptTest do
  @moduledoc """
  The plugin's `c3-attach.sh` against a real HTTP listener: it posts files from disk as
  attachments (a body with quotes, newlines and non-ASCII survives the hand-made JSON),
  opens a thread with them, downloads one back byte for byte, and fails on an HTTP error.
  """
  use C3Web.ConnCase, async: false

  @moduletag :watcher

  @watch Path.expand("../../plugin/skills/c3/scripts/c3-watch.sh", __DIR__)
  @attach Path.expand("../../plugin/skills/c3/scripts/c3-attach.sh", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "c3-attach-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    start_supervised!(
      {Bandit, plug: C3Web.Endpoint, ip: {127, 0, 0, 1}, port: port, startup_log: false}
    )

    %{dir: dir, port: port}
  end

  defp fresh_conn, do: with_ip(build_conn(), unique_ip())

  defp authed(token), do: put_req_header(fresh_conn(), "authorization", "Bearer " <> token)

  defp session! do
    created = fresh_conn() |> post(~p"/v1/sessions", %{}) |> json_response(201)
    %{"session_code" => code, "secret" => secret, "agent" => %{"token" => t1}} = created

    %{"agent" => %{"token" => t2}} =
      fresh_conn()
      |> post(~p"/v1/sessions/#{code}/join", %{"secret" => secret})
      |> json_response(201)

    %{code: code, t1: t1, t2: t2}
  end

  defp env(ctx), do: [{"C3_STATE_DIR", Path.join(ctx.dir, "state")}]

  defp save!(ctx, s, name, token) do
    {out, 0} =
      System.cmd(
        "sh",
        ["-c", ~s(printf '%s\\n' "$T" | sh "$0" save "$1" "$2" "$3"), @watch] ++
          ["http://127.0.0.1:#{ctx.port}", s.code, name],
        env: [{"T", token} | env(ctx)]
      )

    String.trim(out)
  end

  defp attach(ctx, args, opts \\ []) do
    System.cmd("sh", [@attach | args], [env: env(ctx), stderr_to_stdout: true] ++ opts)
  end

  test "open, post with a tricky body, get back byte for byte", ctx do
    s = session!()
    key = save!(ctx, s, "AG1", s.t1)

    log = Path.join(ctx.dir, "build output.log")
    File.write!(log, "line 1\nline \"2\"\n")
    bin = Path.join(ctx.dir, "blob.bin")
    bytes = :crypto.strong_rand_bytes(70_000)
    File.write!(bin, bytes)

    {out, 0} =
      attach(ctx, ["open", key, "--title", "Logs", "--to", "AG2", "--body", "Look", log])

    assert %{
             "id" => "T1",
             "messages" => [%{"attachments" => [%{"filename" => "build output.log"}]}]
           } =
             Jason.decode!(out)

    body = "Quotes \" and \\ back\\slash\n\ttab, ñandú ✓"

    {out, 0} = attach(ctx, ["post", key, "T1", "--body", body, bin, log])

    assert %{"messages" => [%{"kind" => "note", "body" => ^body, "attachments" => [a, b]}]} =
             Jason.decode!(out)

    assert %{"filename" => "blob.bin", "size_bytes" => 70_000} = a
    assert b["filename"] == "build output.log"

    # The other agent reads it through the API, and downloads it with the script.
    assert %{"messages" => [_, %{"body" => ^body}]} =
             authed(s.t2) |> get(~p"/v1/threads/T1") |> json_response(200)

    key2 = save!(ctx, s, "AG2", s.t2)
    target = Path.join(ctx.dir, "copy.bin")
    {out, 0} = attach(ctx, ["get", key2, to_string(a["id"]), target])
    assert String.trim(out) == target
    assert File.read!(target) == bytes
  end

  test "an HTTP error exits 1 with the error, a usage error exits 2", ctx do
    s = session!()
    key = save!(ctx, s, "AG1", s.t1)
    file = Path.join(ctx.dir, "a.txt")
    File.write!(file, "x")

    {out, 1} = attach(ctx, ["post", key, "T9", file])
    assert out =~ "HTTP 404"

    {_out, 2} = attach(ctx, ["post", key, "T1"])
    {_out, 2} = attach(ctx, ["open", key, file])
    {_out, 2} = attach(ctx, ["get", "no-such-key", "1"])

    {out, 1} = attach(ctx, ["get", key, "999999", Path.join(ctx.dir, "none")])
    assert out =~ "HTTP 404"
    refute File.exists?(Path.join(ctx.dir, "none"))
  end
end
