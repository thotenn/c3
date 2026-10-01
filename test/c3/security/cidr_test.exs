defmodule C3.Security.CIDRTest do
  use ExUnit.Case, async: true

  alias C3.Security.CIDR

  test "IPv4 blocks" do
    assert CIDR.member?("10.1.2.3", ["10.0.0.0/8"])
    refute CIDR.member?("11.1.2.3", ["10.0.0.0/8"])
    assert CIDR.member?({192, 168, 1, 9}, ["192.168.1.9"])
    assert CIDR.member?("8.8.8.8", ["0.0.0.0/0"])
  end

  test "IPv6 blocks, and IPv4-mapped addresses match as IPv4" do
    assert CIDR.member?("fd00::1", ["fc00::/7"])
    refute CIDR.member?("2001:db8::1", ["fc00::/7"])
    assert CIDR.member?("::ffff:10.0.0.1", ["10.0.0.0/8"])
    refute CIDR.member?("10.0.0.1", ["::/0"])
  end

  test "invalid input" do
    assert CIDR.parse("10.0.0.0/33") == :error
    assert CIDR.parse("nope/8") == :error
    assert_raise ArgumentError, fn -> CIDR.parse!("10.0.0.0/x") end
    refute CIDR.member?("not-an-ip", ["0.0.0.0/0"])
  end

  test "to_string/1 is canonical" do
    assert CIDR.to_string({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}) == "10.0.0.1"
    assert CIDR.to_string({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}) == "2001:db8::1"
  end
end
