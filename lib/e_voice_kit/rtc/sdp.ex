defmodule EVoiceKit.RTC.SDP do
  @moduledoc """
  Session Description Protocol (SDP) helper for Unified Plan WebRTC transceivers.

  See `docs/ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md` (Section 12) and `docs/adr/0003-unified-plan-webrtc-topology.md`.
  """

  @doc """
  Generates a synthetic SDP answer for an audio offer when operating in headless/fallback mode.
  """
  @spec generate_audio_answer(String.t()) :: String.t()
  def generate_audio_answer(_offer_sdp) do
    """
    v=0\r
    o=- #{System.system_time(:second)} 2 IN IP4 127.0.0.1\r
    s=-\r
    t=0 0\r
    a=group:BUNDLE 0\r
    m=audio 9 UDP/TLS/RTP/SAVPF 111\r
    c=IN IP4 0.0.0.0\r
    a=rtcp-mux\r
    a=mid:0\r
    a=sendrecv\r
    a=rtpmap:111 opus/48000/2\r
    a=fmtp:111 minptime=10;useinbandfec=1\r
    """
  end

  @doc """
  Verifies if an SDP offer contains an audio section with Opus support.
  """
  @spec has_opus?(String.t()) :: boolean()
  def has_opus?(sdp) when is_binary(sdp) do
    String.contains?(String.downcase(sdp), "opus/48000")
  end
end
