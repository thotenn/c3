defmodule C3Web.V1.AttachmentController do
  @moduledoc """
  `GET /v1/attachments/{id}`: the file of an attachment of the agent's session, always as a
  download (`Content-Disposition: attachment`, `nosniff`, a sandboxing CSP), whatever its
  `content_type` says. `?format=json` answers it inline instead — the metadata and the content
  as text or base64, up to `attachment_inline_max_bytes` — which is what `c3_get_attachment`
  uses.
  """
  use C3Web, :controller

  alias C3.Attachments
  alias C3Web.V1.ThreadJSON

  action_fallback C3Web.V1.FallbackController

  def show(conn, %{"id" => id} = params) do
    with {:ok, attachment} <- Attachments.fetch(conn.assigns.current_agent, id) do
      if params["format"] == "json" do
        with {:ok, inline} <- Attachments.read_inline(attachment) do
          json(conn, Map.merge(ThreadJSON.attachment(attachment), inline))
        end
      else
        send_attachment(conn, attachment)
      end
    end
  end

  @doc "Sends `attachment` as a download; shared with the admin pages."
  def send_attachment(conn, attachment) do
    etag = ~s("#{attachment.sha256}")

    conn =
      conn
      |> put_resp_header("content-disposition", disposition(attachment.filename))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("etag", etag)

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      conn
      |> put_resp_content_type(attachment.content_type, nil)
      |> send_file(200, Attachments.path(attachment))
    end
  end

  # An ASCII fallback for old clients plus the exact name (RFC 6266 / 5987).
  defp disposition(filename) do
    ascii = filename |> String.replace(~r/[^\x20-\x7e]|[\\\\%]/u, "_")

    ~s(attachment; filename="#{ascii}"; filename*=UTF-8''#{URI.encode(filename, &URI.char_unreserved?/1)})
  end
end
