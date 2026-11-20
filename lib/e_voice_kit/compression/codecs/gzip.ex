defmodule EVoiceKit.Compression.Codecs.Gzip do
  @moduledoc """
  RFC 1952 GZIP stream compression codec using Erlang's built-in `:zlib`
  with genuine bounded streaming decompression preventing decompression bomb attacks.
  """
  @behaviour EVoiceKit.Compression.Codecs.Codec

  @default_max_plain 2 * 1024 * 1024

  @impl true
  def compress(data, _opts \\ []) when is_binary(data) do
    {:ok, :zlib.gzip(data)}
  rescue
    e -> {:error, {:gzip_compression_failed, e}}
  end

  @impl true
  def decompress(data, opts \\ []) when is_binary(data) do
    max_plain = Keyword.get(opts, :max_plain_length, @default_max_plain)
    decompress_bounded(data, max_plain)
  end

  @doc """
  Decompresses GZIP data with an enforced maximum output byte threshold.
  Terminates immediately if decompressed output exceeds `max_bytes`.
  """
  def decompress_bounded(data, max_bytes) when is_binary(data) and is_integer(max_bytes) do
    z = :zlib.open()

    try do
      # 31 = 16 (gzip) + 15 (max window size)
      :zlib.inflateInit(z, 31)
      buf_size = min(max_bytes + 1, 32_768)
      :zlib.setBufSize(z, buf_size)
      safe_stream_inflate(z, data, max_bytes, 0, [])
    catch
      {:error, reason} -> {:error, reason}
    after
      :zlib.close(z)
    end
  rescue
    e -> {:error, {:gzip_decompression_failed, e}}
  end

  defp safe_stream_inflate(z, data, max_bytes, total_bytes, acc) do
    case :zlib.safeInflate(z, data) do
      {:continue, output} ->
        chunk = IO.iodata_to_binary(output)
        new_total = total_bytes + byte_size(chunk)

        if new_total > max_bytes do
          throw({:error, :decompression_limit_exceeded})
        else
          safe_stream_inflate(z, <<>>, max_bytes, new_total, [acc, chunk])
        end

      {:finished, output} ->
        chunk = IO.iodata_to_binary(output)
        new_total = total_bytes + byte_size(chunk)

        if new_total > max_bytes do
          throw({:error, :decompression_limit_exceeded})
        else
          {:ok, IO.iodata_to_binary([acc, chunk])}
        end

      {:error, reason} ->
        {:error, {:zlib_error, reason}}
    end
  end

  @impl true
  def algorithm, do: :gzip

  @impl true
  def available?, do: true
end
