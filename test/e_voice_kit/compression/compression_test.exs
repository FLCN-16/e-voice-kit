defmodule EVoiceKit.Compression.CompressionTest do
  use ExUnit.Case, async: true

  alias EVoiceKit.Compression.{BoundedDecoder, BoundedEncoder, Negotiation}

  describe "Negotiation" do
    test "negotiates directional algorithms with common codecs" do
      neg = Negotiation.new(priority: [:gzip, :none])

      client_hello = %{
        "encoders" => ["gzip", "none"],
        "decoders" => ["gzip", "none"]
      }

      assert {:ok, neg, server_hello} = Negotiation.handle_client_hello(neg, client_hello)
      assert server_hello["selected_client_to_server"] == "gzip"
      assert server_hello["selected_server_to_client"] == "gzip"

      client_ready = %{"negotiation_id" => neg.negotiation_id}
      assert {:ok, active_neg, server_ready} = Negotiation.handle_client_ready(neg, client_ready)
      assert server_ready["status"] == "active"
      assert active_neg.state == :active

      assert Negotiation.validate_inbound_algorithm(active_neg, :gzip) == :ok
      assert Negotiation.validate_inbound_algorithm(active_neg, :none) == :ok
    end

    test "falls back to :none when client supports no compressed codecs" do
      neg = Negotiation.new()

      client_hello = %{
        "encoders" => ["none"],
        "decoders" => ["none"]
      }

      assert {:ok, _neg, server_hello} = Negotiation.handle_client_hello(neg, client_hello)
      assert server_hello["selected_client_to_server"] == "none"
      assert server_hello["selected_server_to_client"] == "none"
    end

    test "handles asymmetric client encoder/decoder capabilities" do
      neg = Negotiation.new(priority: [:gzip, :none])

      client_hello = %{
        "encoders" => ["gzip"],
        "decoders" => ["none"] # Client can only decode NONE
      }

      assert {:ok, _neg, server_hello} = Negotiation.handle_client_hello(neg, client_hello)
      assert server_hello["selected_client_to_server"] == "gzip"
      assert server_hello["selected_server_to_client"] == "none"
    end
  end

  describe "BoundedEncoder and BoundedDecoder" do
    test "skips compression below size threshold" do
      tiny_payload = "hello world"
      assert {:ok, env} = BoundedEncoder.encode(tiny_payload, :gzip, 1, threshold: 256)
      assert env.compressed == false
      assert env.algorithm == :none
      assert env.payload == tiny_payload

      assert {:ok, decoded} = BoundedDecoder.decode(env, [])
      assert decoded == tiny_payload
    end

    test "compresses with GZIP above threshold and successfully decodes" do
      # Repetitive payload that compresses well
      large_payload = String.duplicate("The quick brown fox jumps over the lazy dog. ", 50)
      assert byte_size(large_payload) > 1000

      assert {:ok, env} = BoundedEncoder.encode(large_payload, :gzip, 10, threshold: 256)
      assert env.compressed == true
      assert env.algorithm == :gzip
      assert byte_size(env.payload) < byte_size(large_payload)
      assert env.plain_length == byte_size(large_payload)

      assert {:ok, decoded} = BoundedDecoder.decode(env, [])
      assert decoded == large_payload
    end

    test "safely handles decompression bomb / expansion ratio breach" do
      # Create a simulated bomb envelope with 1000:1 ratio
      bomb_env = %EVoiceKit.Compression.Envelope{
        message_type: 1,
        compressed: true,
        algorithm: :gzip,
        plain_length: 500_000,
        payload: <<1, 2, 3, 4, 5>>
      }

      assert {:error, :expansion_ratio_exceeded} =
               BoundedDecoder.decode(bomb_env, max_expansion_ratio: 15.0)
    end
  end
end
