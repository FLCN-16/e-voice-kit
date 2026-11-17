defmodule VoiceGateway.Pipeline.BufferTest do
  use ExUnit.Case, async: true
  alias VoiceGateway.Pipeline.Buffer

  describe "Buffer operations" do
    test "accumulates chunks and yields exact 160-byte packets" do
      buf = Buffer.new(160)

      # Push 100 bytes (less than 1 packet)
      {packets1, buf1} = Buffer.push(buf, :binary.copy(<<0>>, 100))
      assert packets1 == []
      assert Buffer.pending_bytes(buf1) == 100

      # Push another 100 bytes (total 200 -> yields 1 packet of 160, 40 remaining)
      {packets2, buf2} = Buffer.push(buf1, :binary.copy(<<1>>, 100))
      assert length(packets2) == 1
      assert byte_size(hd(packets2)) == 160
      assert Buffer.pending_bytes(buf2) == 40
    end

    test "flush/1 immediately clears pending audio on barge-in" do
      buf = Buffer.new(160)
      {_packets, buf1} = Buffer.push(buf, :binary.copy(<<0>>, 150))
      assert Buffer.pending_bytes(buf1) == 150

      flushed = Buffer.flush(buf1)
      assert Buffer.pending_bytes(flushed) == 0
    end
  end
end
