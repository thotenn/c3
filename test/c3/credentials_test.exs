defmodule C3.CredentialsTest do
  use ExUnit.Case, async: true

  alias C3.Credentials

  test "a code is C3-XXXX-XXXX in Crockford base32" do
    for _ <- 1..50 do
      code = Credentials.generate_code()
      assert code =~ ~r/^C3-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/
      assert Credentials.normalize_code(code) == {:ok, code}
    end
  end

  test "codes do not repeat" do
    codes = for _ <- 1..1000, do: Credentials.generate_code()
    assert length(Enum.uniq(codes)) == 1000
  end

  test "normalize_code/1 forgives case, separators, prefix and look-alikes" do
    for input <- ["c3-7kq9-xm2p", "7KQ9XM2P", " C3 7KQ9 XM2P ", "C3-7KQ9-XM2P"] do
      assert Credentials.normalize_code(input) == {:ok, "C3-7KQ9-XM2P"}
    end

    assert Credentials.normalize_code("C3-OIL0-0000") == {:ok, "C3-0110-0000"}
  end

  test "normalize_code/1 rejects what cannot be a code" do
    for input <- ["", "C3-7KQ9", "C3-7KQ9-XM2P-0", "C3-7KQ9-XM2U", nil, 42] do
      assert Credentials.normalize_code(input) == :error
    end
  end

  test "a secret has the configured digits" do
    assert Credentials.generate_secret() =~ ~r/^\d{6}$/
    assert Credentials.generate_secret(8) =~ ~r/^\d{8}$/
  end

  test "the secret is stored as Argon2id and verified ignoring spaces" do
    hash = Credentials.hash_secret("482913")
    assert hash =~ ~r/^\$argon2id\$/
    assert Credentials.verify_secret("482 913", hash)
    refute Credentials.verify_secret("482914", hash)
    refute Credentials.verify_secret(nil, hash)
  end

  test "a token carries 256 bits and hashes deterministically to SHA-256 hex" do
    "c3_" <> encoded = token = Credentials.generate_token()
    assert byte_size(Base.url_decode64!(encoded, padding: false)) == 32
    assert Credentials.hash_token(token) =~ ~r/^[0-9a-f]{64}$/
    assert Credentials.hash_token(token) == Credentials.hash_token(token)
    refute Credentials.hash_token(token) == Credentials.hash_token(Credentials.generate_token())
  end
end
