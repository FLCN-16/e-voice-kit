defmodule EVoiceKit.Compression.BoundedDecoder do
  @moduledoc """
  Bounded decompression engine protecting against decompression bombs, resource exhaustion,
  and corrupted payload streams.

  See `docs/ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md` (Section 11) and `docs/adr/0002-compression-binary-envelope-and-negotiation.md`.
  """

  alias EVoiceKit.Compression.Envelope
  alias EVoiceKit.Compression.Codecs.Gzip

  @default_max_plain_length 2 * 1024 * 1024
  @default_max_expansion_ratio 15.0

  @doc """
  Decompresses the payload of an `%EVoiceKit.Compression.Envelope{}` struct within strictly safe limits.
  Enforces streaming output caps during decompression to prevent decompression bombs.
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
        # Pass effective cap to codec so decompression is bounded at runtime
        effective_cap = min(declared_plain, max_plain)
        codec_opts = Keyword.put(opts, :max_plain_length, effective_cap)
        decompress_with_codec(env.algorithm, env.payload, declared_plain, codec_opts)
    end
  end

  defp decompress_with_codec(:none, payload, _declared, _opts), do: {:ok, payload}

  defp decompress_with_codec(:gzip, payload, declared_plain, opts) do
    case Gzip.decompress(payload, opts) do
      {:ok, decompressed} -> verify_length(decompressed, declared_plain)
      err -> err
    end
  end

  # The pinned Brotli and Zstandard NIF APIs expose whole-buffer decompression only.
  # Reject them here rather than allocate unbounded output before checking its size.
  defp decompress_with_codec(algo, _payload, _declared_plain, _opts)
       when algo in [:brotli, :zstd] do
    {:error, :bounded_decompression_unsupported}
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
