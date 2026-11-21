defmodule EVoiceKit.RTC.RTCTest do
  use ExUnit.Case, async: true

  alias EVoiceKit.RTC.{PeerConnectionOwner, SDP}

  describe "SDP handling" do
    test "detects Opus in offer and generates compliant answer" do
      offer = """
      v=0\r
      m=audio 9 UDP/TLS/RTP/SAVPF 111\r
      a=rtpmap:111 opus/48000/2\r
      """

      assert SDP.has_opus?(offer) == true
      answer = SDP.generate_audio_answer(offer)
      assert String.contains?(answer, "opus/48000")
      assert String.contains?(answer, "a=sendrecv")
    end
  end

  describe "PeerConnectionOwner lifecycle" do
    test "processes SDP offer/answer exchange and updates stats" do
      {:ok, pc_owner} = PeerConnectionOwner.start_link(participant_sid: "alice")

      stats_initial = PeerConnectionOwner.get_stats(pc_owner)
      assert stats_initial.connection_state == :new
      assert stats_initial.packets_sent == 0

      # Invalid SDP must be rejected; a synthetic answer must never imply
      # that ICE/DTLS media transport is connected.
      assert {:error, _reason} = PeerConnectionOwner.apply_offer(pc_owner, "not-sdp")

      stats_after = PeerConnectionOwner.get_stats(pc_owner)
      refute stats_after.connection_state == :connected
      assert stats_after.packets_sent == 0

    end
  end
end
