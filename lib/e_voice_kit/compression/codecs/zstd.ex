defmodule EVoiceKit.Compression.Codecs.Zstd do
  @moduledoc """
  RFC 8878 Zstandard compression codec.
  Uses Erlang `:ezstd` NIF (minimum verified release 1.2.5, patched against CVE-2026-119434).
  """
  @behaviour EVoiceKit.Compression.Codecs.Codec

  @impl true
  def compress(data, _opts \\ []) when is_binary(data) do
    if available?() do
      case apply(:ezstd, :compress, [data]) do
        {:ok, compressed} -> {:ok, compressed}
        compressed when is_binary(compressed) -> {:ok, compressed}
        {:error, reason} -> {:error, {:zstd_compression_failed, reason}}
      end
    else
      {:error, :zstd_not_available}
    end
  rescue
    e -> {:error, {:zstd_compression_failed, e}}
  end

  @impl true
  def decompress(data, _opts \\ []) when is_binary(data) do
    if available?() do
      case apply(:ezstd, :decompress, [data]) do
        {:ok, decompressed} -> {:ok, decompressed}
        decompressed when is_binary(decompressed) -> {:ok, decompressed}
        {:error, reason} -> {:error, {:zstd_decompression_failed, reason}}
      end
    else
      {:error, :zstd_not_available}
    end
  rescue
    e -> {:error, {:zstd_decompression_failed, e}}
  end

  @impl true
  def algorithm, do: :zstd

  @impl true
  def available? do
    Code.ensure_loaded?(:ezstd) and function_exported?(:ezstd, :compress, 1)
  end
end
