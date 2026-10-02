defmodule C3.AttachmentsTest do
  # Touches the shared attachments directory (and swaps it in one test): not async.
  use C3.DataCase, async: false

  import C3.Fixtures

  alias C3.{Attachments, Config, Events, Threads}
  alias C3.Sessions.Lifecycle
  alias C3.Threads.Attachment

  setup do
    session = session_fixture()
    ag1 = agent_fixture(session, %{number: 1})
    ag2 = agent_fixture(session, %{number: 2, label: "backend"})
    ag3 = agent_fixture(session, %{number: 3})
    # Ids come back after a sandbox rollback: drop what an earlier test left under this one.
    File.rm_rf(session_dir(session.id))
    %{session: session, ag1: ag1, ag2: ag2, ag3: ag3}
  end

  defp put_config(key, value) do
    previous = Application.get_env(:c3, key)

    Application.put_env(:c3, key, value)
    # Unset before: delete it again, or `C3.Config.get/1` would read nil instead of the default.
    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:c3, key),
        else: Application.put_env(:c3, key, previous)
    end)
  end

  defp text(name, content), do: %{"filename" => name, "text" => content}

  defp open(author, to, attachments) do
    Threads.open_thread(author, %{
      "title" => "Logs",
      "body" => "See attached",
      "to" => to,
      "attachments" => attachments
    })
  end

  defp attachments_of(message_id) do
    Repo.all(from a in Attachment, where: a.message_id == ^message_id, order_by: a.id)
  end

  describe "prepare/1" do
    test "text and base64, with default content types and the sha256" do
      assert {:ok, [t, b]} =
               Attachments.prepare([
                 text("diff.patch", "--- a\n+++ b\n"),
                 %{"filename" => "logo.png", "base64" => Base.encode64(<<137, 80, 78, 71>>)}
               ])

      assert %{filename: "diff.patch", content_type: "text/plain; charset=utf-8", size: 12} = t
      assert t.sha256 == :crypto.hash(:sha256, "--- a\n+++ b\n") |> Base.encode16(case: :lower)
      assert %{content_type: "application/octet-stream", data: <<137, 80, 78, 71>>} = b

      assert {:ok, [%{content_type: "application/json"}]} =
               Attachments.prepare([
                 %{"filename" => "x.json", "text" => "{}", "content_type" => "application/json"}
               ])

      assert {:ok, []} = Attachments.prepare(nil)
    end

    test "base64 with whitespace or without padding decodes" do
      encoded = Base.encode64("hello world") |> String.trim_trailing("=")
      wrapped = String.slice(encoded, 0, 4) <> "\n" <> String.slice(encoded, 4..-1//1)

      assert {:ok, [%{data: "hello world"}]} =
               Attachments.prepare([%{"filename" => "a.bin", "base64" => wrapped}])
    end

    test "rejects what is malformed" do
      for bad <- [
            "not a list",
            [%{"filename" => "a"}],
            [%{"text" => "no name"}],
            [%{"filename" => "a", "text" => "x", "base64" => "eA=="}],
            [%{"filename" => "a", "base64" => "@@@"}],
            [%{"filename" => "/", "text" => "x"}],
            [%{"filename" => "a", "text" => "x", "content_type" => "not a type"}],
            ["a string"]
          ] do
        assert {:error, {:invalid, _message, _details}} = Attachments.prepare(bad),
               "accepted #{inspect(bad)}"
      end
    end

    test "limits: per file, per post and the number of files" do
      put_config(:attachment_max_bytes, 10)
      put_config(:attachments_message_max_bytes, 15)

      assert {:error, {:too_large, "Attachment big.txt is over 10 bytes"}} =
               Attachments.prepare([text("big.txt", String.duplicate("x", 11))])

      assert {:error, {:too_large, _}} =
               Attachments.prepare([text("a", "1234567890"), text("b", "123456")])

      assert {:ok, [_, _]} = Attachments.prepare([text("a", "1234567890"), text("b", "12345")])

      many = for n <- 1..(Config.get(:attachments_per_message) + 1), do: text("f#{n}", "x")
      assert {:error, {:invalid, _, %{attachments: ["too many"]}}} = Attachments.prepare(many)
    end

    test "filenames keep only their last segment, without control characters or quotes" do
      assert {:ok, "passwd"} = Attachments.sanitize_filename("../../etc/passwd")
      assert {:ok, "evil.txt"} = Attachments.sanitize_filename("C:\\tmp\\evil.txt")
      assert {:ok, "ab.txt"} = Attachments.sanitize_filename("a\"\nb.txt")
      assert {:ok, "informe ñandú.pdf"} = Attachments.sanitize_filename("informe ñandú.pdf")
      assert :error = Attachments.sanitize_filename("..")

      {:ok, long} = Attachments.sanitize_filename(String.duplicate("ñ", 200))
      assert byte_size(long) <= 255 and String.valid?(long)
    end
  end

  describe "posting with attachments" do
    test "a thread to several targets: one file on disk, a row per request", ctx do
      {:ok, thread} = open(ctx.ag1, ["AG2", "AG3"], [text("build.log", "ok\n")])

      [r1, r2] = Threads.list_messages(thread)
      assert [%{filename: "build.log", size_bytes: 3} = a1] = r1.attachments
      assert [a2] = r2.attachments
      assert a1.storage_key == a2.storage_key
      assert a1.storage_key =~ ~r"^#{ctx.session.id}/[0-9a-f]{32}$"
      assert File.read!(Attachments.path(a1)) == "ok\n"
      assert Attachments.session_bytes(ctx.session.id) == 3

      [event] = for e <- Events.list_after(ctx.session, 0), e.type == :thread_opened, do: e
      assert event.payload["attachments"] == ["build.log"]
    end

    test "a response carries them, and message.posted names them", ctx do
      {:ok, thread} = open(ctx.ag1, "AG2", nil)

      {:ok, %{messages: [response]}} =
        Threads.post_message(ctx.ag2, thread, %{
          "kind" => "response",
          "body" => "Done",
          "attachments" => [text("result.json", ~s({"ok":true}))]
        })

      assert [%{content_type: "text/plain; charset=utf-8"}] = attachments_of(response.id)

      posted = for e <- Events.list_after(ctx.session, 0), e.type == :message_posted, do: e
      assert [%{payload: %{"attachments" => ["result.json"]}}] = posted
    end

    test "without attachments the payload has no attachments key", ctx do
      {:ok, _thread} = open(ctx.ag1, "AG2", nil)
      [event] = for e <- Events.list_after(ctx.session, 0), e.type == :thread_opened, do: e
      refute Map.has_key?(event.payload, "attachments")
    end

    test "the session quota counts each file once and refuses the post that goes over", ctx do
      put_config(:attachments_session_max_bytes, 10)

      {:ok, thread} = open(ctx.ag1, ["AG2", "AG3"], [text("a", "123456")])
      assert Attachments.session_bytes(ctx.session.id) == 6

      assert {:error, {:too_large, message}} =
               Threads.post_message(ctx.ag1, thread, %{
                 "kind" => "note",
                 "body" => "more",
                 "attachments" => [text("b", "12345")]
               })

      assert message =~ "6 used"
      # The note was rolled back with its file.
      assert length(Threads.list_messages(thread)) == 2
      assert files_on_disk(ctx.session.id) == 1
    end

    test "a post that fails after writing leaves no file behind", ctx do
      {:ok, thread} = open(ctx.ag1, "AG2", nil)
      {:ok, _} = Threads.finish(ctx.ag1, thread, %{"force" => true})

      assert {:error, {:conflict, _, _}} =
               Threads.post_message(ctx.ag1, thread, %{
                 "kind" => "note",
                 "body" => "late",
                 "attachments" => [text("late.txt", "x")]
               })

      assert files_on_disk(ctx.session.id) == 0
    end
  end

  describe "reading" do
    test "fetch/2 stays in the agent's session", ctx do
      {:ok, thread} = open(ctx.ag1, "AG2", [text("a.txt", "x")])
      [%{attachments: [attachment]}] = Threads.list_messages(thread)

      assert {:ok, %Attachment{}} = Attachments.fetch(ctx.ag2, attachment.id)
      assert {:ok, _} = Attachments.fetch(ctx.ag2, to_string(attachment.id))

      other = agent_fixture(session_fixture(), %{number: 1})
      assert {:error, :attachment_not_found} = Attachments.fetch(other, attachment.id)
      assert {:error, :attachment_not_found} = Attachments.fetch(ctx.ag2, "nope")
    end

    test "read_inline/1: text, base64 for binaries, refused over the inline limit", ctx do
      {:ok, thread} =
        open(ctx.ag1, "AG2", [
          text("a.txt", "héllo"),
          %{"filename" => "b.bin", "base64" => Base.encode64(<<0, 1, 2>>)}
        ])

      [%{attachments: [t, b]}] = Threads.list_messages(thread)
      assert {:ok, %{encoding: "text", content: "héllo"}} = Attachments.read_inline(t)
      assert {:ok, %{encoding: "base64", content: "AAEC"}} = Attachments.read_inline(b)

      put_config(:attachment_inline_max_bytes, 2)
      assert {:error, {:too_large, message}} = Attachments.read_inline(t)
      assert message =~ "GET /v1/attachments/#{t.id}"
    end
  end

  describe "purge and orphans" do
    test "purging a session deletes its rows and its files", ctx do
      {:ok, _thread} = open(ctx.ag1, "AG2", [text("a.txt", "x")])
      assert files_on_disk(ctx.session.id) == 1

      {:ok, _} = C3.Sessions.close(ctx.ag1)
      assert {:ok, _} = Lifecycle.purge_session(ctx.session.id)

      assert Repo.aggregate(Attachment, :count) == 0
      refute File.exists?(session_dir(ctx.session.id))
    end

    test "sweep_orphans/1 deletes old files without a row and dirs of gone sessions", ctx do
      put_config(:attachments_dir, Path.join(System.tmp_dir!(), "c3-orphans-#{unique_int()}"))
      on_exit(fn -> File.rm_rf(Config.attachments_dir()) end)

      {:ok, _thread} = open(ctx.ag1, "AG2", [text("kept.txt", "x")])
      File.write!(Path.join(session_dir(ctx.session.id), "stray"), "x")
      gone = Path.join(Config.attachments_dir(), "999999999")
      File.mkdir_p!(gone)
      File.write!(Path.join(gone, "old"), "x")

      # Within the grace hour nothing goes: a post may still be in its transaction.
      assert Attachments.sweep_orphans() == 0

      later = DateTime.add(DateTime.utc_now(), 2 * 3600, :second)
      assert Attachments.sweep_orphans(later) == 2
      assert files_on_disk(ctx.session.id) == 1
      refute File.exists?(gone)
    end
  end

  defp session_dir(session_id), do: Path.join(Config.attachments_dir(), to_string(session_id))

  defp files_on_disk(session_id) do
    case File.ls(session_dir(session_id)) do
      {:ok, files} -> length(files)
      {:error, _} -> 0
    end
  end
end
