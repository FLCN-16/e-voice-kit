defmodule EVoiceKit.SFU.PacketMapper do
  @moduledoc """
  High-performance RTP packet header rewriting and translation for selective forwarding.

  Translates payload type and SSRC between publisher UpTracks and subscriber DownTracks
  without decoding the underlying media payload.

  See `docs/ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md` (Section 15 & 16).
  """

  alias EVoiceKit.SFU.DownTrack

  @doc """
  Parses the 12-byte fixed header of an RTP packet.
  """
  @spec parse_header(binary()) :: {:ok, map()} | {:error, atom()}
  def parse_header(
        <<2::2, p::1, x::1, cc::4, m::1, pt::7, seq::16, ts::32, ssrc::32, payload::binary>>
      ) do
    {:ok,
     %{
       version: 2,
       padding: p,
       extension: x,
       csrc_count: cc,
       marker: m,
       payload_type: pt,
       sequence_number: seq,
       timestamp: ts,
       ssrc: ssrc,
       payload: payload
     }}
  end

  def parse_header(binary) when is_binary(binary) and byte_size(binary) < 12 do
    {:error, :rtp_packet_too_short}
  end

  def parse_header(<<v::2, _rest::binary>>) when v != 2 do
    {:error, :unsupported_rtp_version}
  end

  def parse_header(_), do: {:error, :malformed_rtp_packet}

  @doc """
  Rewrites an incoming RTP packet for egress over a specific DownTrack.
  Remaps the SSRC and payload type in place while preserving the media payload.
  """
  @spec rewrite_for_down_track(binary(), DownTrack.t()) :: {:ok, binary()} | {:error, term()}
  def rewrite_for_down_track(
        <<2::2, p::1, x::1, cc::4, m::1, _pt::7, seq::16, ts::32, _src_ssrc::32,
          rest_payload::binary>>,
        %DownTrack{} = down_track
      ) do
    dest_pt = down_track.destination_pt
    dest_ssrc = down_track.destination_ssrc

    # Compute sequence and timestamp with offsets if configured
    dest_seq = rem(seq + down_track.seq_offset, 65536)
    dest_ts = rem(ts + down_track.ts_offset, 4_294_967_296)

    rewritten = <<
      2::2,
      p::1,
      x::1,
      cc::4,
      m::1,
      dest_pt::7,
      dest_seq::16,
      dest_ts::32,
      dest_ssrc::32,
      rest_payload::binary
    >>

    {:ok, rewritten}
  end

  def rewrite_for_down_track(_invalid_packet, _down_track) do
    {:error, :invalid_rtp_packet}
  end
end
