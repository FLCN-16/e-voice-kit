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

      offer = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n"
      assert {:ok, answer} = PeerConnectionOwner.apply_offer(pc_owner, offer)
      assert String.contains?(answer, "opus/48000")

      stats_after = PeerConnectionOwner.get_stats(pc_owner)
      assert stats_after.connection_state == :connected

      # Simulate receiving forwarded RTP from SFU
      send(pc_owner, {:forwarded_rtp, "tr_1", <<2::2, 0::14, 0::16, 0::32, 0::32, "payload">>})
      :timer.sleep(10)

      stats_forwarded = PeerConnectionOwner.get_stats(pc_owner)
      assert stats_forwarded.packets_sent == 1
    end
  end
end
