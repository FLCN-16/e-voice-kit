defmodule EVoiceKit.Compression.EnvelopeTest do
  use ExUnit.Case, async: true

  alias EVoiceKit.Compression.Envelope

  describe "encode/1 and decode/2 round-trips" do
    test "encodes and decodes an uncompressed message (NONE)" do
      payload = "{\"type\":\"join\",\"room\":\"room_123\"}"

      envelope = %Envelope{
        message_type: 101,
        control: false,
        compressed: false,
        algorithm: :none,
        request_id: 42,
        payload: payload
      }

      assert {:ok, binary} = Envelope.encode(envelope)
      assert byte_size(binary) == 28 + byte_size(payload)

      # Header layout assertions
      assert <<
               "EVK1",
               1::8,
               0::8, # flags: uncompressed, data
               0::8, # algo: none
               28::8, # header len
               101::16, # msg type
               0::16, # reserved
               wire_len::32,
               plain_len::32,
               42::64,
               rest::binary
             >> = binary

      assert wire_len == byte_size(payload)
      assert plain_len == byte_size(payload)
      assert rest == payload

      assert {:ok, decoded} = Envelope.decode(binary)
      assert decoded.message_type == 101
      assert decoded.compressed == false
      assert decoded.control == false
      assert decoded.algorithm == :none
      assert decoded.request_id == 42
      assert decoded.payload == payload
      assert decoded.plain_length == byte_size(payload)
    end

    test "encodes and decodes a compressed control message (ZSTD)" do
      compressed_payload = <<1, 2, 3, 4, 5, 6, 7, 8>>

      envelope = %Envelope{
        message_type: 205,
        control: true,
        compressed: true,
        algorithm: :zstd,
        plain_length: 32,
        request_id: 9999,
        payload: compressed_payload
      }

      assert {:ok, binary} = Envelope.encode(envelope)
      assert {:ok, decoded} = Envelope.decode(binary)

      assert decoded.message_type == 205
      assert decoded.control == true
      assert decoded.compressed == true
      assert decoded.algorithm == :zstd
      assert decoded.plain_length == 32
      assert decoded.request_id == 9999
      assert decoded.payload == compressed_payload
    end
  end

  describe "decode/2 validation and error handling" do
    test "rejects frame shorter than 28 bytes" do
      short_frame = <<"EVK1", 1, 0, 0>>
      assert {:error, :frame_too_short} = Envelope.decode(short_frame)
    end

    test "rejects invalid magic" do
      invalid_magic = <<
        "XXXX",
        1::8,
        0::8,
        0::8,
        28::8,
        1::16,
        0::16,
        4::32,
        4::32,
        0::64,
        "test"
      >>

      assert {:error, :invalid_magic} = Envelope.decode(invalid_magic)
    end

    test "rejects unsupported version" do
      unsupported_version = <<
        "EVK1",
        2::8, # Version 2
        0::8,
        0::8,
        28::8,
        1::16,
        0::16,
        4::32,
        4::32,
        0::64,
        "test"
      >>

      assert {:error, :unsupported_version} = Envelope.decode(unsupported_version)
    end

    test "rejects invalid header length" do
      bad_header_len = <<
        "EVK1",
        1::8,
        0::8,
        0::8,
        32::8, # Should be 28
        1::16,
        0::16,
        4::32,
        4::32,
        0::64,
        "test"
      >>

      assert {:error, :invalid_header_length} = Envelope.decode(bad_header_len)
    end

    test "rejects non-zero reserved bytes" do
      bad_reserved = <<
        "EVK1",
        1::8,
        0::8,
        0::8,
        28::8,
        1::16,
        1::16, # Reserved must be 0
        4::32,
        4::32,
        0::64,
        "test"
      >>

      assert {:error, :reserved_bits_not_zero} = Envelope.decode(bad_reserved)
    end

    test "rejects reserved flag bits" do
      bad_flags = <<
        "EVK1",
        1::8,
        0b00000100::8, # Bit 2 is reserved
        0::8,
        28::8,
        1::16,
        0::16,
        4::32,
        4::32,
        0::64,
        "test"
      >>

      assert {:error, :reserved_flags_not_zero} = Envelope.decode(bad_flags)
    end

    test "rejects payload length mismatch" do
      mismatched_payload = <<
        "EVK1",
        1::8,
        0::8,
        0::8,
        28::8,
        1::16,
        0::16,
        10::32, # Declared 10 bytes wire
        10::32,
        0::64,
        "short" # Only 5 bytes
      >>

      assert {:error, :payload_length_mismatch} = Envelope.decode(mismatched_payload)
    end

    test "rejects unknown algorithm ID" do
      unknown_algo = <<
        "EVK1",
        1::8,
        1::8,
        99::8, # Algorithm ID 99 unknown
        28::8,
        1::16,
        0::16,
        4::32,
        10::32,
        0::64,
        "data"
      >>

      assert {:error, {:unknown_algorithm_id, 99}} = Envelope.decode(unknown_algo)
    end

    test "rejects uncompressed frame declaring non-none algorithm" do
      inconsistent = <<
        "EVK1",
        1::8,
        0::8, # uncompressed
        2::8, # but algorithm brotli
        28::8,
        1::16,
        0::16,
        4::32,
        4::32,
        0::64,
        "data"
      >>

      assert {:error, :uncompressed_flag_with_non_none_algorithm} = Envelope.decode(inconsistent)
    end

    test "rejects compressed frame declaring none algorithm" do
      inconsistent = <<
        "EVK1",
        1::8,
        1::8, # compressed
        0::8, # algorithm none
        28::8,
        1::16,
        0::16,
        4::32,
        10::32,
        0::64,
        "data"
      >>

      assert {:error, :compressed_flag_with_none_algorithm} = Envelope.decode(inconsistent)
    end

    test "rejects decompression bomb exceeding max expansion ratio" do
      bomb = <<
        "EVK1",
        1::8,
        1::8, # compressed
        3::8, # zstd
        28::8,
        1::16,
        0::16,
        10::32, # 10 bytes wire
        10_000::32, # 10,000 bytes plain (1000:1 ratio)
        0::64,
        "1234567890"
      >>

      assert {:error, :expansion_ratio_exceeded} =
               Envelope.decode(bomb, max_expansion_ratio: 15.0)
    end

    test "rejects wire length exceeding max limit" do
      large_wire = <<
        "EVK1",
        1::8,
        0::8,
        0::8,
        28::8,
        1::16,
        0::16,
        500::32,
        500::32,
        0::64,
        :binary.copy(<<"a">>, 500)
      >>

      assert {:error, :wire_length_exceeded} =
               Envelope.decode(large_wire, max_wire_length: 200)
    end
  end
end
