defmodule EVoiceKit.Transports.CarrierTest do
  use ExUnit.Case, async: true

  alias EVoiceKit.Transports.{TwilioWebSocket, TelnyxWebSocket, VonageWebSocket}
  alias EVoiceKit.Transports.SIP.{RTP, Message}

  describe "WebSocket Carriers" do
    test "TwilioWebSocket correctly parses start and media events" do
      state = %TwilioWebSocket{}

      start_payload = %{
        "event" => "start",
        "start" => %{
          "streamSid" => "MZ_test_123",
          "callSid" => "CA_test_456",
          "customParameters" => %{
            "tenant_id" => "tenant_1",
            "stt_provider" => "deepgram",
            "tts_provider" => "elevenlabs"
          }
        }
      }

      assert {:ok, "MZ_test_123", opts, new_state} = TwilioWebSocket.parse_start_event(start_payload, state)
      assert opts[:tenant_id] == "tenant_1"
      assert opts[:stt_provider] == :deepgram
      assert opts[:tts_provider] == :elevenlabs
      assert new_state.carrier_data.call_sid == "CA_test_456"

      # Media Event
      raw_mulaw = <<1, 2, 3, 4, 5>>
      media_payload = %{
        "event" => "media",
        "media" => %{
          "payload" => Base.encode64(raw_mulaw)
        }
      }

      assert {:ok, ^raw_mulaw, _} = TwilioWebSocket.parse_media_event(media_payload, new_state)

      # Outbound encoding
      state_with_call = %{new_state | call_id: "MZ_test_123"}
      assert {:reply, {:text, json_frame}, _} = TwilioWebSocket.encode_media_frame(raw_mulaw, state_with_call)
      decoded = Jason.decode!(json_frame)
      assert decoded["event"] == "media"
      assert decoded["streamSid"] == "MZ_test_123"
      assert decoded["media"]["payload"] == Base.encode64(raw_mulaw)

      # Clear frame (barge-in)
      assert {:reply, {:text, clear_json}, _} = TwilioWebSocket.encode_clear_frame(state_with_call)
      assert Jason.decode!(clear_json)["event"] == "clear"

      # Mark frame (synchronization)
      assert {:reply, {:text, mark_json}, _} = TwilioWebSocket.encode_mark_frame("turn_1_done", state_with_call)
      decoded_mark = Jason.decode!(mark_json)
      assert decoded_mark["event"] == "mark"
      assert decoded_mark["streamSid"] == "MZ_test_123"
      assert decoded_mark["mark"]["name"] == "turn_1_done"
    end

    test "TelnyxWebSocket correctly parses start event and encoded client_state" do
      state = %TelnyxWebSocket{}

      client_state = Jason.encode!(%{"tenant_id" => "tenant_telnyx", "stt_provider" => "sarvam"})
      start_payload = %{
        "event" => "start",
        "stream_id" => "stream_telnyx_001",
        "call_control_id" => "cc_001",
        "client_state" => Base.encode64(client_state)
      }

      assert {:ok, "stream_telnyx_001", opts, _} = TelnyxWebSocket.parse_start_event(start_payload, state)
      assert opts[:tenant_id] == "tenant_telnyx"
      assert opts[:stt_provider] == :sarvam
    end

    test "VonageWebSocket correctly parses connected and media events" do
      state = %VonageWebSocket{}

      start_payload = %{
        "event" => "websocket:connected",
        "uuid" => "vonage_call_789",
        "from" => "+14155551234",
        "to" => "+18005559999"
      }

      assert {:ok, "vonage_call_789", opts, _} = VonageWebSocket.parse_start_event(start_payload, state)
      assert opts[:caller_number] == "+14155551234"
      assert opts[:dialed_number] == "+18005559999"
    end
  end

  describe "SIP / RTP Codec & Parser" do
    test "RTP encode and decode roundtrip" do
      payload = :crypto.strong_rand_bytes(160)
      seq_num = 42
      timestamp = 9600
      ssrc = 123_456_789

      packet = RTP.encode(payload, seq_num, timestamp, ssrc)

      assert {:ok, decoded} = RTP.decode(packet)
      assert decoded.version == 2
      assert decoded.payload_type == 0
      assert decoded.sequence_number == 42
      assert decoded.timestamp == 9600
      assert decoded.ssrc == 123_456_789
      assert decoded.payload == payload
    end

    test "SIP Message parses INVITE request and extracts SDP audio port" do
      raw_sip = """
      INVITE sip:+14155550199@gateway.domain.com SIP/2.0\r
      Via: SIP/2.0/UDP carrier.com:5060;branch=z9hG4bK776\r
      From: <sip:+18005551111@carrier.com>;tag=1234\r
      To: <sip:+14155550199@gateway.domain.com>\r
      Call-ID: a84b4c76e66710@carrier.com\r
      CSeq: 1 INVITE\r
      Content-Type: application/sdp\r
      \r
      v=0\r
      o=carrier 123 456 IN IP4 198.51.100.1\r
      s=Call\r
      c=IN IP4 198.51.100.1\r
      t=0 0\r
      m=audio 20000 RTP/AVP 0\r
      """

      msg = Message.parse(raw_sip)
      assert msg.method == "INVITE"
      assert msg.headers["Call-ID"] == "a84b4c76e66710@carrier.com"
      assert msg.headers["Content-Type"] == "application/sdp"

      assert {:ok, ip, port} = Message.parse_sdp_audio(msg.body)
      assert ip == "198.51.100.1"
      assert port == 20000
    end
  end
end
