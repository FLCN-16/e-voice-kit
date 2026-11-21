defmodule EVoiceKit.SFU.SFUTest do
  use ExUnit.Case, async: true

  alias EVoiceKit.SFU.{DownTrack, PacketMapper, Router, UpTrack}

  describe "PacketMapper" do
    test "parses RTP fixed header" do
      # 12-byte RTP header + 4 byte payload:
      # V=2, P=0, X=0, CC=0, M=1, PT=111 (0x6F), Seq=1000, TS=96000, SSRC=12345
      packet = <<
        2::2,
        0::1,
        0::1,
        0::4,
        1::1,
        111::7,
        1000::16,
        96000::32,
        12345::32,
        "opus"
      >>

      assert {:ok, parsed} = PacketMapper.parse_header(packet)
      assert parsed.version == 2
      assert parsed.payload_type == 111
      assert parsed.sequence_number == 1000
      assert parsed.timestamp == 96000
      assert parsed.ssrc == 12345
      assert parsed.payload == "opus"
    end

    test "rewrites PT and SSRC for DownTrack" do
      src_packet = <<
        2::2,
        0::1,
        0::1,
        0::4,
        0::1,
        111::7,
        100::16,
        48000::32,
        11111::32,
        "media_bytes"
      >>

      down_track = %DownTrack{
        subscriber_sid: "sub_1",
        track_sid: "tr_1",
        sink_pid: self(),
        destination_pt: 96,
        destination_ssrc: 99999,
        seq_offset: 10,
        ts_offset: 20
      }

      assert {:ok, rewritten} = PacketMapper.rewrite_for_down_track(src_packet, down_track)
      assert {:ok, parsed} = PacketMapper.parse_header(rewritten)

      assert parsed.payload_type == 96
      assert parsed.ssrc == 99999
      assert parsed.sequence_number == 110
      assert parsed.timestamp == 48020
      assert parsed.payload == "media_bytes"
    end
  end

  describe "SFU Router End-to-End Fan-Out" do
    test "routes packet from publisher UpTrack to multiple subscriber DownTracks" do
      {:ok, router} = Router.start_link()

      # 1. Register publisher UpTrack
      up_track = UpTrack.new("track_audio_1", "publisher_alice", ssrc: 11111, payload_type: 111)
      assert :ok = Router.register_up_track(router, up_track)

      # 2. Subscribe Subscriber Bob and Subscriber Charlie
      bob_sink = self()
      {:ok, _bob_down} = Router.subscribe(router, "bob", "track_audio_1", bob_sink, destination_ssrc: 22222)

      # 3. Forward packet
      rtp_packet = <<
        2::2,
        0::1,
        0::1,
        0::4,
        1::1,
        111::7,
        500::16,
        100_000::32,
        11111::32,
        "opus_sample"
      >>

      Router.forward_packet(router, "track_audio_1", rtp_packet)

      # Bob's sink should receive the forwarded packet
      assert_receive {:forwarded_rtp, "track_audio_1", forwarded_bytes}, 500
      assert {:ok, parsed} = PacketMapper.parse_header(forwarded_bytes)
      assert parsed.ssrc == 22222
      assert parsed.payload == "opus_sample"

      # 4. Unsubscribe and verify no more packets delivered
      assert :ok = Router.unsubscribe(router, "bob", "track_audio_1")
      Router.forward_packet(router, "track_audio_1", rtp_packet)
      refute_receive {:forwarded_rtp, _, _}, 100
    end
  end
end
