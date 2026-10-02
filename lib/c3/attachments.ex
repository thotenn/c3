defmodule C3.Attachments do
  @moduledoc """
  The files a message carries (spec, *Seguridad › Otros*; `schema.md` §9).

  A post brings them inline, `[{filename, content_type?, text | base64}]`: `prepare/1`
  checks and decodes them before the transaction, `store!/4` writes them inside it. The
  content goes to disk, `<attachments_dir>/<session_id>/<128 random bits>`, never under a
  name derived from the client's filename; the row keeps the metadata. A file is written to
  a temporary name and renamed, and the files written by a transaction that rolls back are
  deleted (`with_cleanup/1`), so a failed post leaves nothing behind. Whatever still slips
  through — a crash between the write and the commit — is removed by `sweep_orphans/1`.

  Limits (`C3.Config`): `attachment_max_bytes` per file, `attachments_message_max_bytes` per
  post, `attachments_session_max_bytes` per session (a file sent to several targets counts
  once) and `attachments_per_message` files per post.

  Errors are those of `C3.Threads`: `{:invalid, message, details}` and `{:too_large,
  message}`; a read of an attachment outside the agent's session is `:attachment_not_found`.
  """
  import Ecto.Query

  alias C3.{Config, Repo}
  alias C3.Sessions.{Agent, Session}
  alias C3.Threads.{Attachment, Message}

  @written {__MODULE__, :written}
  @orphan_grace_seconds 3600
  @content_type ~r/^[a-z0-9][a-z0-9!#$&^_.+-]*\/[a-z0-9][a-z0-9!#$&^_.+-]*(\s*;.*)?$/i

  @type prepared :: %{
          filename: String.t(),
          content_type: String.t(),
          data: binary(),
          size: non_neg_integer(),
          sha256: String.t()
        }

  ## Before the transaction

  @doc """
  Checks and decodes the `attachments` of a post (`nil` = none). Returns `{:ok, [prepared]}`
  or `{:error, reason}`.
  """
  def prepare(nil), do: {:ok, []}
  def prepare([]), do: {:ok, []}

  def prepare(items) when is_list(items) do
    max_count = Config.get(:attachments_per_message)

    if length(items) > max_count do
      invalid("At most #{max_count} attachments per message", %{attachments: ["too many"]})
    else
      items
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
        case prepare_one(item, index) do
          {:ok, file} -> {:cont, {:ok, [file | acc]}}
          error -> {:halt, error}
        end
      end)
      |> check_total()
    end
  end

  def prepare(_items) do
    invalid("attachments must be a list", %{attachments: ["must be a list"]})
  end

  defp prepare_one(%{} = item, index) do
    max = Config.get(:attachment_max_bytes)

    with {:ok, filename} <- filename(item["filename"], index),
         {:ok, data, default_type} <- content(item, index),
         :ok <- check_size(data, max, filename),
         {:ok, content_type} <- content_type(item["content_type"], default_type, index) do
      {:ok,
       %{
         filename: filename,
         content_type: content_type,
         data: data,
         size: byte_size(data),
         sha256: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
       }}
    end
  end

  defp prepare_one(_item, index) do
    invalid("Each attachment must be an object", %{
      "attachments.#{index}" => ["must be an object"]
    })
  end

  defp content(%{"text" => text, "base64" => _}, index) when is_binary(text) do
    invalid("An attachment carries text or base64, not both", %{
      "attachments.#{index}" => ["text and base64 are exclusive"]
    })
  end

  defp content(%{"text" => text}, _index) when is_binary(text),
    do: {:ok, text, "text/plain; charset=utf-8"}

  defp content(%{"base64" => encoded}, index) when is_binary(encoded) do
    case Base.decode64(String.replace(encoded, ~r/\s+/, ""), padding: false) do
      {:ok, data} -> {:ok, data, "application/octet-stream"}
      :error -> invalid("Invalid base64", %{"attachments.#{index}.base64" => ["is not base64"]})
    end
  end

  defp content(_item, index) do
    invalid("An attachment needs text or base64", %{
      "attachments.#{index}" => ["needs text or base64"]
    })
  end

  defp check_size(data, max, filename) do
    if byte_size(data) > max,
      do: {:error, {:too_large, "Attachment #{filename} is over #{max} bytes"}},
      else: :ok
  end

  defp check_total({:ok, files}) do
    max = Config.get(:attachments_message_max_bytes)
    total = files |> Enum.map(& &1.size) |> Enum.sum()

    if total > max,
      do: {:error, {:too_large, "The attachments of a message are over #{max} bytes together"}},
      else: {:ok, Enum.reverse(files)}
  end

  defp check_total(error), do: error

  @doc """
  The name a client-supplied `filename` is stored under: its last path segment, without
  control characters or quotes, at most 255 bytes. `:error` when nothing is left.
  """
  def sanitize_filename(name) when is_binary(name) do
    name =
      name
      |> String.split(["/", "\\"])
      |> List.last()
      |> String.replace(~r/[\x00-\x1f\x7f"]/u, "")
      |> String.trim()
      |> truncate(255)

    if name in ["", ".", ".."], do: :error, else: {:ok, name}
  end

  def sanitize_filename(_name), do: :error

  defp filename(name, index) do
    with true <- is_binary(name) and String.valid?(name),
         {:ok, name} <- sanitize_filename(name) do
      {:ok, name}
    else
      _ -> invalid("Invalid filename", %{"attachments.#{index}.filename" => ["is invalid"]})
    end
  end

  defp content_type(nil, default, _index), do: {:ok, default}

  defp content_type(type, _default, index) when is_binary(type) do
    if byte_size(type) <= 255 and Regex.match?(@content_type, type),
      do: {:ok, type},
      else:
        invalid("Invalid content_type", %{"attachments.#{index}.content_type" => ["is invalid"]})
  end

  defp content_type(_type, _default, index) do
    invalid("Invalid content_type", %{"attachments.#{index}.content_type" => ["is invalid"]})
  end

  # Cuts at a character boundary.
  defp truncate(name, max) when byte_size(name) <= max, do: name

  defp truncate(name, max) do
    name
    |> String.graphemes()
    |> Enum.reduce_while("", fn g, acc ->
      if byte_size(acc) + byte_size(g) > max, do: {:halt, acc}, else: {:cont, acc <> g}
    end)
  end

  defp invalid(message, details), do: {:error, {:invalid, message, details}}

  ## Inside the transaction

  @doc """
  Runs `fun` (a `Repo.transaction/1`) and deletes the files `store!/4` wrote inside it when
  it does not return `{:ok, _}`.
  """
  def with_cleanup(fun) do
    Process.put(@written, [])

    try do
      result = fun.()
      unless match?({:ok, _}, result), do: Enum.each(Process.get(@written, []), &File.rm/1)
      result
    rescue
      error ->
        Enum.each(Process.get(@written, []), &File.rm/1)
        reraise error, __STACKTRACE__
    after
      Process.delete(@written)
    end
  end

  @doc """
  Writes the `files` once and attaches them to every message of `messages` (the requests of
  a post to several targets share them). Checks the session's quota first, with the
  session row locked so two posts cannot both fit in the last megabyte. Call inside a
  transaction wrapped in `with_cleanup/1`. Returns the attachments.
  """
  def store!(_session_id, _messages, [], _now), do: []

  def store!(session_id, messages, files, now) do
    {1, _} =
      Repo.update_all(from(s in Session, where: s.id == ^session_id), set: [updated_at: now])

    check_quota!(session_id, files)

    stored = Enum.map(files, &Map.put(&1, :storage_key, write!(session_id, &1.data)))

    for %Message{id: message_id} <- messages, file <- stored do
      %Attachment{message_id: message_id, session_id: session_id}
      |> Attachment.changeset(%{
        filename: file.filename,
        content_type: file.content_type,
        size_bytes: file.size,
        sha256: file.sha256,
        storage_key: file.storage_key
      })
      |> Repo.insert!()
    end
  end

  defp check_quota!(session_id, files) do
    max = Config.get(:attachments_session_max_bytes)
    used = session_bytes(session_id)
    adding = files |> Enum.map(& &1.size) |> Enum.sum()

    if used + adding > max do
      Repo.rollback(
        {:too_large, "The session's attachments would go over #{max} bytes (#{used} used)"}
      )
    end
  end

  @doc "The bytes a session's attachments take on disk (each file once)."
  def session_bytes(session_id) do
    files =
      from a in Attachment,
        where: a.session_id == ^session_id,
        group_by: a.storage_key,
        select: %{size: max(a.size_bytes)}

    Repo.one(from f in subquery(files), select: coalesce(sum(f.size), 0)) || 0
  end

  defp write!(session_id, data) do
    key = "#{session_id}/#{Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}"
    path = path(key)
    tmp = path <> ".tmp"

    File.mkdir_p!(Path.dirname(path))
    File.write!(tmp, data)
    File.rename!(tmp, path)
    Process.put(@written, [path | Process.get(@written, [])])
    key
  end

  ## Reads

  @doc "Attachment `id` of the agent's session, or `{:error, :attachment_not_found}`."
  def fetch(%Agent{session_id: session_id}, id), do: fetch_in(session_id, id)

  @doc "Attachment `id` of session `session_id` (the admin's download)."
  def fetch_in(session_id, id) do
    with {id, ""} <- parse_id(id),
         %Attachment{} = attachment <- Repo.get_by(Attachment, id: id, session_id: session_id) do
      {:ok, attachment}
    else
      _ -> {:error, :attachment_not_found}
    end
  end

  defp parse_id(id) when is_integer(id), do: {id, ""}
  defp parse_id(id) when is_binary(id), do: Integer.parse(id)
  defp parse_id(_id), do: :error

  @doc "Where the content of an attachment (or a `storage_key`) is on disk."
  def path(%Attachment{storage_key: key}), do: path(key)
  def path(key) when is_binary(key), do: Path.join(Config.attachments_dir(), key)

  @doc """
  The content of an attachment for a JSON answer: `{:ok, %{encoding: "text" | "base64",
  content}}` — text when it is valid UTF-8 without NUL bytes — or `{:error, {:too_large,
  message}}` over `attachment_inline_max_bytes`.
  """
  def read_inline(%Attachment{} = attachment) do
    max = Config.get(:attachment_inline_max_bytes)

    if attachment.size_bytes > max do
      {:error,
       {:too_large,
        "Attachment #{attachment.id} is over #{max} bytes: download it from " <>
          "GET /v1/attachments/#{attachment.id}"}}
    else
      data = File.read!(path(attachment))

      if String.valid?(data) and not String.contains?(data, <<0>>),
        do: {:ok, %{encoding: "text", content: data}},
        else: {:ok, %{encoding: "base64", content: Base.encode64(data)}}
    end
  end

  ## Purge

  @doc "Deletes the directory of a session's files. Call after its rows are gone."
  def delete_session_files(session_id) do
    File.rm_rf(Path.join(Config.attachments_dir(), Integer.to_string(session_id)))
    :ok
  end

  @doc """
  Deletes what is on disk with no row behind it, older than an hour (so a post still in its
  transaction keeps its files): the directories of sessions that no longer exist, and the
  files no attachment points at. Run by `C3.Sweeper`; returns how many it deleted.
  """
  def sweep_orphans(now \\ DateTime.utc_now()) do
    dir = Config.attachments_dir()
    cutoff = DateTime.to_unix(now) - @orphan_grace_seconds

    case File.ls(dir) do
      {:ok, entries} -> entries |> Enum.map(&sweep_session_dir(dir, &1, cutoff)) |> Enum.sum()
      {:error, _} -> 0
    end
  end

  defp sweep_session_dir(dir, entry, cutoff) do
    session_dir = Path.join(dir, entry)

    with {session_id, ""} <- Integer.parse(entry),
         {:ok, files} <- File.ls(session_dir) do
      if Repo.exists?(from s in Session, where: s.id == ^session_id) do
        keys =
          from(a in Attachment, where: a.session_id == ^session_id, select: a.storage_key)
          |> Repo.all()
          |> MapSet.new()

        files
        |> Enum.reject(&MapSet.member?(keys, "#{session_id}/#{&1}"))
        |> Enum.count(&remove_if_old(Path.join(session_dir, &1), cutoff))
      else
        if old?(session_dir, cutoff) do
          File.rm_rf(session_dir)
          length(files)
        else
          0
        end
      end
    else
      _ -> 0
    end
  end

  defp remove_if_old(path, cutoff) do
    old?(path, cutoff) and File.rm(path) == :ok
  end

  defp old?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime < cutoff
      _ -> false
    end
  end
end
