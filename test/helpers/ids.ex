defmodule Frame.Test.Ids do
  @moduledoc "Random v4 UUIDs for tests."
  def uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> =
      Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    "#{p1}-#{p2}-#{p3}-#{p4}-#{p5}"
  end
end
