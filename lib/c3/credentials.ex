defmodule C3.Credentials do
  @moduledoc """
  Generation and hashing of the three credentials of a session (`schema.md`, *Credenciales*):

    * `session_code` — `C3-XXXX-XXXX`, 40 random bits in Crockford base32. Stored in clear.
    * `secret` — the numeric security number (`C3.Config` `:secret_digits`). Stored as an
      Argon2id hash: low entropy needs a slow hash.
    * agent token — 256 random bits. Stored as its SHA-256: high entropy makes a fast,
      deterministic hash enough, and lets a request find its agent by `token_hash`.
  """
  import Bitwise

  @alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @code_chars 8

  @doc "A fresh `C3-XXXX-XXXX` session code."
  def generate_code do
    <<n::40>> = :crypto.strong_rand_bytes(5)

    chars =
      for i <- (@code_chars - 1)..0//-1, into: "" do
        <<Enum.at(@alphabet, n >>> (5 * i) &&& 31)>>
      end

    format_code(chars)
  end

  @doc """
  Normalizes a code as typed by a person or an agent: case, separators, the optional `C3`
  prefix and Crockford's look-alikes (`O` → `0`, `I`/`L` → `1`). `:error` if it cannot be a code.
  """
  def normalize_code(input) when is_binary(input) do
    chars =
      input
      |> String.upcase()
      |> String.replace(~r/[^0-9A-Z]/, "")
      |> String.replace("O", "0")
      |> String.replace(~r/[IL]/, "1")

    chars = if byte_size(chars) == @code_chars + 2, do: strip_prefix(chars), else: chars

    if byte_size(chars) == @code_chars and
         Enum.all?(String.to_charlist(chars), &(&1 in @alphabet)) do
      {:ok, format_code(chars)}
    else
      :error
    end
  end

  def normalize_code(_), do: :error

  defp strip_prefix("C3" <> rest), do: rest
  defp strip_prefix(chars), do: chars

  defp format_code(<<a::binary-size(4), b::binary-size(4)>>), do: "C3-#{a}-#{b}"

  @doc "A fresh numeric secret with `digits` digits, zero-padded."
  def generate_secret(digits \\ C3.Config.get(:secret_digits)) do
    <<n::64>> = :crypto.strong_rand_bytes(8)

    n
    |> rem(Integer.pow(10, digits))
    |> Integer.to_string()
    |> String.pad_leading(digits, "0")
  end

  @doc "The Argon2id hash stored in `sessions.secret_hash`."
  def hash_secret(secret), do: Argon2.hash_pwd_salt(secret)

  @doc "Whether `secret` (spaces ignored) matches `secret_hash`."
  def verify_secret(secret, secret_hash) when is_binary(secret) do
    Argon2.verify_pass(String.replace(secret, ~r/\s/, ""), secret_hash)
  end

  def verify_secret(_secret, _secret_hash), do: Argon2.no_user_verify()

  @doc "Spends the time of a secret check, so an unknown code does not answer faster."
  def dummy_verify, do: Argon2.no_user_verify()

  @doc "A fresh agent token."
  def generate_token,
    do: "c3_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc "The SHA-256 (hex) stored in `agents.token_hash`."
  def hash_token(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
end
