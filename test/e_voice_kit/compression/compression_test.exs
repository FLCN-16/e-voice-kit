defmodule EVoiceKit.Compression.CompressionTest do
  use ExUnit.Case, async: true

  alias EVoiceKit.Compression.Codecs.{Brotli, Gzip, Zstd}
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
        "decoders" => ["none"]
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

    test "enforces streaming output limit when envelope forged length is small" do
      large_payload = String.duplicate("A", 10_000)
      {:ok, compressed} = Gzip.compress(large_payload)

      # Attacker forges plain_length as 50 to evade pre-check
      forged_env = %EVoiceKit.Compression.Envelope{
        message_type: 1,
        compressed: true,
        algorithm: :gzip,
        plain_length: 50,
        payload: compressed
      }

      # Gzip bounded streaming decompression must abort because decompressed output exceeds 50
      assert {:error, :decompression_limit_exceeded} = BoundedDecoder.decode(forged_env, [])
    end

    test "round-trips Zstandard when ezstd NIF is available" do
      if Zstd.available?() do
        payload = String.duplicate("Realtime WebRTC Zstd Media Stream ", 40)
        assert {:ok, compressed} = Zstd.compress(payload)
        assert {:ok, decompressed} = Zstd.decompress(compressed)
        assert decompressed == payload
      end
    end

    test "round-trips Brotli when brotli NIF is available" do
      if Brotli.available?() do
        payload = String.duplicate("Realtime WebRTC Brotli Signaling Stream ", 40)
        assert {:ok, compressed} = Brotli.compress(payload)
        assert {:ok, decompressed} = Brotli.decompress(compressed)
        assert decompressed == payload
      end
    end
  end
end
