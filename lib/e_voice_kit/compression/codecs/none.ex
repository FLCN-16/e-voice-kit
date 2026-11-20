defmodule EVoiceKit.Compression.Codecs.None do
  @moduledoc """
  Uncompressed pass-through codec (mandatory baseline for all clients).
  """
  @behaviour EVoiceKit.Compression.Codecs.Codec

  @impl true
  def compress(data, _opts \\ []), do: {:ok, data}

  @impl true
  def decompress(data, _opts \\ []), do: {:ok, data}

  @impl true
  def algorithm, do: :none

  @impl true
  def available?, do: true
end
