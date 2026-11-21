defmodule EVoiceKit.Signaling.SessionTest do
  use ExUnit.Case, async: true

  alias EVoiceKit.Auth.Token
  alias EVoiceKit.Compression.{BoundedDecoder, Envelope}
  alias EVoiceKit.Signaling.{Protocol, Session}

  describe "Full Signaling Lifecycle: ClientHello -> ClientReady -> JoinRoom -> PublishTrack" do
    test "completes negotiation and processes room messages with authenticated token" do
      {:ok, session} = Session.start_link()

      # 1. Send ClientHello
      client_hello = %{
        "type" => "client_hello",
        "protocol_version" => "1.0",
        "encoders" => ["none", "gzip"],
        "decoders" => ["none", "gzip"]
      }

      hello_payload = Jason.encode!(client_hello)

      hello_env = %Envelope{
        message_type: Protocol.msg_type(:client_hello),
        compressed: false,
        algorithm: :none,
        plain_length: byte_size(hello_payload),
        request_id: 1,
        payload: hello_payload
      }

      {:ok, hello_binary} = Envelope.encode(hello_env)
      assert {:ok, [server_hello_bin]} = Session.handle_frame(session, hello_binary)

      assert {:ok, server_hello_env} = Envelope.decode(server_hello_bin)
      assert server_hello_env.message_type == Protocol.msg_type(:server_hello)
      assert {:ok, server_hello_json} = BoundedDecoder.decode(server_hello_env, [])
      server_hello_data = Jason.decode!(server_hello_json)
      negotiation_id = server_hello_data["negotiation_id"]
      assert is_binary(negotiation_id)

      # 2. Send ClientReady
      client_ready = %{
        "type" => "client_ready",
        "negotiation_id" => negotiation_id
      }

      ready_payload = Jason.encode!(client_ready)

      ready_env = %Envelope{
        message_type: Protocol.msg_type(:client_ready),
        compressed: false,
        algorithm: :none,
        plain_length: byte_size(ready_payload),
        request_id: 2,
        payload: ready_payload
      }

      {:ok, ready_binary} = Envelope.encode(ready_env)
      assert {:ok, [server_ready_bin]} = Session.handle_frame(session, ready_binary)

      assert {:ok, server_ready_env} = Envelope.decode(server_ready_bin)
      assert server_ready_env.message_type == Protocol.msg_type(:server_ready)

      # 3. Join Room with cryptographic authentication token
      {:ok, token} =
        Token.generate(%{
          "room" => "test_conference",
          "identity" => "alice",
          "permissions" => %{
            "can_publish" => true,
            "can_subscribe" => true,
            "can_publish_data" => true
          }
        })

      join_req = %{
        "type" => "join_room",
        "room" => "test_conference",
        "identity" => "alice",
        "token" => token
      }

      join_payload = Jason.encode!(join_req)

      join_env = %Envelope{
        message_type: Protocol.msg_type(:join_room),
        compressed: false,
        algorithm: :none,
        plain_length: byte_size(join_payload),
        request_id: 3,
        payload: join_payload
      }

      {:ok, join_binary} = Envelope.encode(join_env)
      assert {:ok, [join_resp_bin]} = Session.handle_frame(session, join_binary)

      assert {:ok, join_resp_env} = Envelope.decode(join_resp_bin)
      assert join_resp_env.message_type == Protocol.msg_type(:join_room_response)
      assert {:ok, join_resp_json} = BoundedDecoder.decode(join_resp_env, [])
      join_data = Jason.decode!(join_resp_json)
      assert join_data["room"] == "test_conference"
      assert join_data["status"] == "joined"

      # 4. Ping / Pong
      ping = %{"type" => "ping", "timestamp" => 12345678}
      ping_payload = Jason.encode!(ping)

      ping_env = %Envelope{
        message_type: Protocol.msg_type(:ping),
        compressed: false,
        algorithm: :none,
        plain_length: byte_size(ping_payload),
        request_id: 4,
        payload: ping_payload
      }

      {:ok, ping_binary} = Envelope.encode(ping_env)
      assert {:ok, [pong_bin]} = Session.handle_frame(session, ping_binary)
      assert {:ok, pong_env} = Envelope.decode(pong_bin)
      assert pong_env.message_type == Protocol.msg_type(:pong)

      # 5. SDP Offer / Answer exchange
      dummy_offer = "v=0\r\no=- 12345 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=audio 5004 UDP/TLS/RTP/SAVPF 111\r\n"
      offer_req = %{"type" => "sdp_offer", "sdp" => dummy_offer}
      offer_payload = Jason.encode!(offer_req)

      offer_env = %Envelope{
        message_type: Protocol.msg_type(:sdp_offer),
        compressed: false,
        algorithm: :none,
        plain_length: byte_size(offer_payload),
        request_id: 5,
        payload: offer_payload
      }

      {:ok, offer_binary} = Envelope.encode(offer_env)
      # The deliberately incomplete SDP fixture must fail negotiation rather than
      # receiving a synthetic SDP answer that falsely reports a usable connection.
      assert {:error, :negotiation_failed, [error_bin]} = Session.handle_frame(session, offer_binary)
      assert {:ok, error_env} = Envelope.decode(error_bin)
      assert error_env.message_type == Protocol.msg_type(:error)

      # 6. Publish Track
      pub_req = %{"type" => "publish_track", "kind" => "audio", "source" => "microphone"}
      pub_payload = Jason.encode!(pub_req)

      pub_env = %Envelope{
        message_type: Protocol.msg_type(:publish_track),
        compressed: false,
        algorithm: :none,
        plain_length: byte_size(pub_payload),
        request_id: 6,
        payload: pub_payload
      }

      {:ok, pub_binary} = Envelope.encode(pub_env)
      assert {:ok, [pub_resp_bin]} = Session.handle_frame(session, pub_binary)
      assert {:ok, pub_resp_env} = Envelope.decode(pub_resp_bin)
      assert pub_resp_env.message_type == Protocol.msg_type(:track_published)
    end

    test "rejects unauthenticated join attempt" do
      {:ok, session} = Session.start_link()

      # Send hello and ready
      {:ok, hello_bin} =
        Envelope.encode(%Envelope{
          message_type: Protocol.msg_type(:client_hello),
          compressed: false,
          algorithm: :none,
          plain_length: 2,
          payload: "{}"
        })

      {:ok, [server_hello_bin]} = Session.handle_frame(session, hello_bin)
      {:ok, env} = Envelope.decode(server_hello_bin)
      {:ok, json} = BoundedDecoder.decode(env, [])
      neg_id = Jason.decode!(json)["negotiation_id"]

      {:ok, ready_bin} =
        Envelope.encode(%Envelope{
          message_type: Protocol.msg_type(:client_ready),
          compressed: false,
          algorithm: :none,
          plain_length: byte_size(neg_id),
          payload: Jason.encode!(%{"negotiation_id" => neg_id})
        })

      {:ok, _} = Session.handle_frame(session, ready_bin)

      # Try to join with missing or invalid token
      join_req = %{"type" => "join_room", "room" => "secure_room", "identity" => "hacker"}
      {:ok, join_bin} =
        Envelope.encode(%Envelope{
          message_type: Protocol.msg_type(:join_room),
          compressed: false,
          algorithm: :none,
          plain_length: 50,
          payload: Jason.encode!(join_req)
        })

      assert {:error, :unauthorized, [err_bin]} = Session.handle_frame(session, join_bin)
      assert {:ok, err_env} = Envelope.decode(err_bin)
      assert err_env.message_type == Protocol.msg_type(:error)
    end

    test "rejects compressed frame sent before negotiation completes" do
      {:ok, session} = Session.start_link()

      illegal_env = %Envelope{
        message_type: Protocol.msg_type(:join_room),
        compressed: true,
        algorithm: :gzip,
        plain_length: 50,
        request_id: 99,
        payload: <<1, 2, 3, 4>>
      }

      {:ok, bin} = Envelope.encode(illegal_env)
      assert {:error, :compressed_frame_before_negotiation_active, [error_bin]} = Session.handle_frame(session, bin)
      assert {:ok, error_env} = Envelope.decode(error_bin)
      assert error_env.message_type == Protocol.msg_type(:error)
    end
  end
end
