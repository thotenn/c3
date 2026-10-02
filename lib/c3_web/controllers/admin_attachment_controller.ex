defmodule C3Web.AdminAttachmentController do
  @moduledoc """
  `GET /admin/sessions/{code}/attachments/{id}`: the admin downloads an attachment, with the
  same headers an agent gets (`C3Web.V1.AttachmentController.send_attachment/2`).
  """
  use C3Web, :controller

  import C3Web.AdminAuth, only: [require_admin: 2]

  alias C3.{Admin, Attachments}
  alias C3Web.V1.AttachmentController

  plug :require_admin

  def show(conn, %{"code" => code, "id" => id}) do
    with %{} = session <- Admin.get_session(code),
         {:ok, attachment} <- Attachments.fetch_in(session.id, id) do
      AttachmentController.send_attachment(conn, attachment)
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end
end
