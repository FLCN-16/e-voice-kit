defmodule EVoiceKit.Compression.BoundedDecoder do
  @moduledoc """
  Bounded decompression engine protecting against decompression bombs, resource exhaustion,
  and corrupted payload streams.

  See `docs/ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md` (Section 11) and `docs/adr/0002-compression-binary-envelope-and-negotiation.md`.
  """

  alias EVoiceKit.Compression.Envelope
  alias EVoiceKit.Compression.Codecs.{Brotli, Gzip, None, Zstd}

  @default_max_plain_length 2 * 1024 * 1024
  @default_max_expansion_ratio 15.0

  @doc """
  Decompresses the payload of an `%EVoiceKit.Compression.Envelope{}` struct within safe limits.
  """
  @spec decode(Envelope.t(), keyword()) :: {:ok, binary()} | {:error, atom() | {atom(), term()}}
  def decode(%Envelope{compressed: false} = env, _opts) do
    {:ok, env.payload}
  end

  def decode(%Envelope{compressed: true} = env, opts) do
    max_plain = Keyword.get(opts, :max_plain_length, @default_max_plain_length)
    max_expansion = Keyword.get(opts, :max_expansion_ratio, @default_max_expansion_ratio)

    wire_size = byte_size(env.payload)
    declared_plain = env.plain_length

    cond do
      declared_plain > max_plain ->
        {:error, :plain_length_exceeded}

      wire_size > 0 and declared_plain / wire_size > max_expansion ->
        {:error, :expansion_ratio_exceeded}

      true ->
        decompress_with_codec(env.algorithm, env.payload, declared_plain, opts)
    end
  end

  defp decompress_with_codec(:none, payload, _declared, _opts), do: {:ok, payload}

  defp decompress_with_codec(:gzip, payload, declared_plain, opts) do
    case Gzip.decompress(payload, opts) do
      {:ok, decompressed} -> verify_length(decompressed, declared_plain)
      err -> err
    end
  end

  defp decompress_with_codec(:brotli, payload, declared_plain, opts) do
    case Brotli.decompress(payload, opts) do
      {:ok, decompressed} -> verify_length(decompressed, declared_plain)
      err -> err
    end
  end

  defp decompress_with_codec(:zstd, payload, declared_plain, opts) do
    case Zstd.decompress(payload, opts) do
      {:ok, decompressed} -> verify_length(decompressed, declared_plain)
      err -> err
    end
  end

  defp decompress_with_codec(algo, _payload, _declared, _opts) do
    {:error, {:unsupported_algorithm, algo}}
  end

  defp verify_length(decompressed, expected_length) when byte_size(decompressed) == expected_length do
    {:ok, decompressed}
  end

  defp verify_length(decompressed, expected_length) do
    {:error,
     {:plain_length_mismatch, actual: byte_size(decompressed), expected: expected_length}}
  end
end
