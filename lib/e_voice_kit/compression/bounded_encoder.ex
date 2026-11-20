defmodule EVoiceKit.Compression.BoundedEncoder do
  @moduledoc """
  Bounded compression engine with minimum size thresholds and negative-compression safeguards.

  If a payload is smaller than the minimum threshold (default 256 bytes) or if compression
  increases the wire size, the encoder sends the payload uncompressed (`NONE`).

  See `docs/ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md` (Section 11) and `docs/adr/0002-compression-binary-envelope-and-negotiation.md`.
  """

  alias EVoiceKit.Compression.Envelope
  alias EVoiceKit.Compression.Codecs.{Brotli, Gzip, None, Zstd}

  @default_threshold 256

  @doc """
  Encodes a payload into an `%EVoiceKit.Compression.Envelope{}` struct, applying compression
  only if eligible, supported, and profitable.
  """
  @spec encode(binary(), atom(), non_neg_integer(), keyword()) ::
          {:ok, Envelope.t()} | {:error, term()}
  def encode(payload, algorithm, message_type, opts \\ []) when is_binary(payload) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    control? = Keyword.get(opts, :control, false)
    request_id = Keyword.get(opts, :request_id, 0)
    plain_len = byte_size(payload)

    if algorithm == :none or plain_len < threshold do
      # Small payload or NONE algorithm: send uncompressed
      {:ok,
       %Envelope{
         message_type: message_type,
         control: control?,
         compressed: false,
         algorithm: :none,
         plain_length: plain_len,
         request_id: request_id,
         payload: payload
       }}
    else
      compress_and_wrap(payload, algorithm, message_type, control?, request_id, plain_len, opts)
    end
  end

  defp compress_and_wrap(payload, algorithm, message_type, control?, request_id, plain_len, opts) do
    case compress_payload(algorithm, payload, opts) do
      {:ok, compressed} when byte_size(compressed) < plain_len ->
        # Compression saved bytes: wrap as compressed
        {:ok,
         %Envelope{
           message_type: message_type,
           control: control?,
           compressed: true,
           algorithm: algorithm,
           plain_length: plain_len,
           request_id: request_id,
           payload: compressed
         }}

      _unprofitable_or_failed ->
        # Compression expanded payload or codec unavailable: fallback to uncompressed NONE
        {:ok,
         %Envelope{
           message_type: message_type,
           control: control?,
           compressed: false,
           algorithm: :none,
           plain_length: plain_len,
           request_id: request_id,
           payload: payload
         }}
    end
  end

  defp compress_payload(:none, payload, _opts), do: None.compress(payload)
  defp compress_payload(:gzip, payload, opts), do: Gzip.compress(payload, opts)
  defp compress_payload(:brotli, payload, opts), do: Brotli.compress(payload, opts)
  defp compress_payload(:zstd, payload, opts), do: Zstd.compress(payload, opts)
  defp compress_payload(_unknown, payload, _opts), do: {:ok, payload}
end
