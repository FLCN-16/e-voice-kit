defmodule EVoiceKit.Compression.Codecs.Gzip do
  @moduledoc """
  RFC 1952 GZIP stream compression codec using Erlang's built-in `:zlib`.
  """
  @behaviour EVoiceKit.Compression.Codecs.Codec

  @impl true
  def compress(data, _opts \\ []) when is_binary(data) do
    {:ok, :zlib.gzip(data)}
  rescue
    e -> {:error, {:gzip_compression_failed, e}}
  end

  @impl true
  def decompress(data, _opts \\ []) when is_binary(data) do
    {:ok, :zlib.gunzip(data)}
  rescue
    e -> {:error, {:gzip_decompression_failed, e}}
  end

  @impl true
  def algorithm, do: :gzip

  @impl true
  def available?, do: true
end
