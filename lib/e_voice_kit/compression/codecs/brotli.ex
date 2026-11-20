defmodule EVoiceKit.Compression.Codecs.Brotli do
  @moduledoc """
  RFC 7932 Brotli stream compression codec.
  Uses Erlang `:brotli` NIF (minimum verified release 0.3.4, patched against EEF-CVE-2026-111497).
  """
  @behaviour EVoiceKit.Compression.Codecs.Codec

  @impl true
  def compress(data, _opts \\ []) when is_binary(data) do
    if available?() do
      case apply(:brotli, :encode, [data]) do
        {:ok, compressed} -> {:ok, compressed}
        compressed when is_binary(compressed) -> {:ok, compressed}
        {:error, reason} -> {:error, {:brotli_compression_failed, reason}}
      end
    else
      {:error, :brotli_not_available}
    end
  rescue
    e -> {:error, {:brotli_compression_failed, e}}
  end

  @impl true
  def decompress(data, _opts \\ []) when is_binary(data) do
    if available?() do
      case apply(:brotli, :decode, [data]) do
        {:ok, decompressed} -> {:ok, decompressed}
        decompressed when is_binary(decompressed) -> {:ok, decompressed}
        {:error, reason} -> {:error, {:brotli_decompression_failed, reason}}
      end
    else
      {:error, :brotli_not_available}
    end
  rescue
    e -> {:error, {:brotli_decompression_failed, e}}
  end

  @impl true
  def algorithm, do: :brotli

  @impl true
  def available? do
    Code.ensure_loaded?(:brotli) and function_exported?(:brotli, :encode, 1)
  end
end
