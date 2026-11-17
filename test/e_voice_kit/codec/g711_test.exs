defmodule EVoiceKit.Codec.G711Test do
  use ExUnit.Case, async: true
  alias EVoiceKit.Codec.G711

  describe "decode_mulaw/1 and encode_mulaw/1" do
    test "decodes silence byte (0xFF) to zero-level PCM" do
      pcm = G711.decode_mulaw(<<0xFF>>)
      assert is_binary(pcm)
      assert byte_size(pcm) == 2
      <<sample::16-little-signed>> = pcm
      assert sample == 0
    end

    test "round-trip preserves audio structure" do
      original = :binary.copy(<<0xFF>>, 160)
      pcm = G711.decode_mulaw(original)
      assert byte_size(pcm) == 320

      re_encoded = G711.encode_mulaw(pcm)
      assert byte_size(re_encoded) == 160
      assert re_encoded == original
    end

    test "handles trailing incomplete half-sample gracefully" do
      # 3 bytes (1 complete 16-bit sample + 1 trailing incomplete byte)
      pcm_with_odd_byte = <<0::16-little-signed, 42>>
      encoded = G711.encode_mulaw(pcm_with_odd_byte)
      assert byte_size(encoded) == 1
    end

    test "silence_mulaw/1 returns correct length binary" do
      silence = G711.silence_mulaw(160)
      assert byte_size(silence) == 160
      assert silence == :binary.copy(<<0xFF>>, 160)
    end
  end

  describe "decode_alaw/1 and encode_alaw/1" do
    test "decodes A-law silence (0xD5) without error" do
      pcm = G711.decode_alaw(<<0xD5>>)
      assert is_binary(pcm)
      assert byte_size(pcm) == 2
    end

    test "round-trip preserves A-law audio structure" do
      original = :binary.copy(<<0xD5>>, 160)
      pcm = G711.decode_alaw(original)
      assert byte_size(pcm) == 320

      re_encoded = G711.encode_alaw(pcm)
      assert byte_size(re_encoded) == 160
      assert re_encoded == original
    end

    test "silence_alaw/1 returns correct length binary" do
      silence = G711.silence_alaw(160)
      assert byte_size(silence) == 160
      assert silence == :binary.copy(<<0xD5>>, 160)
    end
  end
end
