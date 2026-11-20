defmodule EVoiceKit.Compression.Codecs.Codec do
  @moduledoc """
  Behaviour for compression algorithm implementations in E-Voice-Kit.
  """

  @type algorithm :: :none | :gzip | :brotli | :zstd
  @type opts :: keyword()

  @callback compress(binary(), opts()) :: {:ok, binary()} | {:error, term()}
  @callback decompress(binary(), opts()) :: {:ok, binary()} | {:error, term()}
  @callback algorithm() :: algorithm()
  @callback available?() :: boolean()
end
