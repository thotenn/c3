defmodule C3.Threads.Attachment do
  @moduledoc """
  A file carried by a message (`schema.md` §9). The row holds the metadata; the content is
  on disk at `C3.Attachments.path/1`. A post to several targets creates one row per request,
  all with the same `storage_key`: the file is stored, and counted against the session, once.
  """
  use C3.Schema

  alias C3.Sessions.Session
  alias C3.Threads.Message

  schema "attachments" do
    field :filename, :string
    field :content_type, :string
    field :size_bytes, :integer
    field :sha256, :string
    field :storage_key, :string

    belongs_to :message, Message
    belongs_to :session, Session

    timestamps(updated_at: false)
  end

  @fields ~w(filename content_type size_bytes sha256 storage_key)a

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_length(:filename, min: 1, max: 255)
    |> validate_number(:size_bytes, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:session_id)
    |> check_constraint(:size_bytes, name: :attachments_size_check)
  end
end
