defmodule EVoiceKit.Transports.SIP.RTP do
  @moduledoc """
  Native binary codec for Real-time Transport Protocol (RTP) packets (RFC 3550).

  Handles zero-copy serialization and deserialization of 20ms G.711 μ-law / A-law
  audio payloads over UDP.
  """

  @version 2
  @payload_type_pcmu 0
  @payload_type_pcma 8

  @type rtp_packet :: %{
          version: integer(),
          payload_type: integer(),
          sequence_number: integer(),
          timestamp: integer(),
          ssrc: integer(),
          payload: binary()
        }

  @doc """
  Encodes raw 8kHz audio into an RFC 3550 RTP packet.
  Defaults to payload type 0 (PCMU / G.711 μ-law).
  """
  def encode(payload, seq_num, timestamp, ssrc, payload_type \\ @payload_type_pcmu) do
    # 12-byte fixed RTP header:
    # V(2) P(1) X(1) CC(4) | M(1) PT(7) | Sequence Number (16)
    # Timestamp (32)
    # SSRC (32)
    <<
      @version::2,
      0::1,
      0::1,
      0::4,
      0::1,
      payload_type::7,
      seq_num::16,
      timestamp::32,
      ssrc::32,
      payload::binary
    >>
  end

  @doc """
  Decodes an inbound UDP binary datagram into an RTP packet.
  """
  def decode(<<
        @version::2,
        _padding::1,
        _extension::1,
        csrc_count::4,
        _marker::1,
        payload_type::7,
        seq_num::16,
        timestamp::32,
        ssrc::32,
        rest::binary
      >>) do
    # Skip CSRC identifiers if present (4 bytes each)
    csrc_bytes = csrc_count * 4

    case rest do
      <<_csrcs::binary-size(csrc_bytes), payload::binary>> ->
        {:ok,
         %{
           version: 2,
           payload_type: payload_type,
           sequence_number: seq_num,
           timestamp: timestamp,
           ssrc: ssrc,
           payload: payload
         }}

      _ ->
        {:error, :malformed_rtp_header}
    end
  end

  def decode(_invalid_binary), do: {:error, :not_an_rtp_packet}

  def pcmu_type, do: @payload_type_pcmu
  def pcma_type, do: @payload_type_pcma
end
