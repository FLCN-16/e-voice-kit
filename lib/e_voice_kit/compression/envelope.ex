defmodule EVoiceKit.Compression.Envelope do
  @moduledoc """
  Fixed 28-byte binary framing protocol (`EVK1`) for E-Voice-Kit native real-time signaling.

  Defines the application-level envelope for multiplexing and compressing signaling
  and application data over WebSockets and WebRTC DataChannels.

  See `docs/ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md` (Section 10) and `docs/adr/0002-compression-binary-envelope-and-negotiation.md`.

  ### Header Layout (Big-Endian / Network Byte Order)
  ```text
  | Offset | Size | Field                | Type / Meaning                                  |
  |-------:|-----:|----------------------|-------------------------------------------------|
  |      0 |    4 | Magic                | ASCII 'EVK1' (0x45, 0x56, 0x4B, 0x31)           |
  |      4 |    1 | Envelope Version     | 1                                               |
  |      5 |    1 | Flags                | Bit 0: compressed (1), Bit 1: control (1)       |
  |      6 |    1 | Algorithm ID         | 0: NONE, 1: GZIP, 2: BROTLI, 3: ZSTD            |
  |      7 |    1 | Header Length        | 28 (bytes)                                      |
  |      8 |    2 | Message Type         | 16-bit unsigned integer                         |
  |     10 |    2 | Reserved             | 0x0000 (must be zero in V1)                     |
  |     12 |    4 | Wire Payload Length  | 32-bit unsigned integer                         |
  |     16 |    4 | Plain Payload Length | 32-bit unsigned integer                         |
  |     20 |    8 | Request/Corr ID      | 64-bit unsigned integer                         |
  |     28 |    N | Payload              | Binary payload of length Wire Payload Length     |
  ```
  """

  import Bitwise

  @magic "EVK1"
  @version 1
  @header_length 28

  # Algorithm ID mapping
  @algo_none 0
  @algo_gzip 1
  @algo_brotli 2
  @algo_zstd 3

  # Default security limits
  @default_max_wire_length 2 * 1024 * 1024
  @default_max_plain_length 2 * 1024 * 1024
  @default_max_expansion_ratio 15.0

  defstruct [
    :message_type,
    :payload,
    version: 1,
    compressed: false,
    control: false,
    algorithm: :none,
    plain_length: 0,
    request_id: 0
  ]

  @type algorithm :: :none | :gzip | :brotli | :zstd
  @type t :: %__MODULE__{
          version: pos_integer(),
          compressed: boolean(),
          control: boolean(),
          algorithm: algorithm(),
          message_type: non_neg_integer(),
          plain_length: non_neg_integer(),
          request_id: non_neg_integer(),
          payload: binary()
        }

  @doc """
  Encodes an envelope struct into binary format.
  """
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = envelope) do
    flags = build_flags(envelope.compressed, envelope.control)
    algo_id = algorithm_to_id(envelope.algorithm)
    payload = envelope.payload || <<>>
    wire_len = byte_size(payload)
    plain_len = if envelope.compressed, do: envelope.plain_length, else: wire_len
    req_id = envelope.request_id || 0
    msg_type = envelope.message_type || 0

    header = <<
      @magic::binary-size(4),
      @version::8-unsigned-big,
      flags::8-unsigned-big,
      algo_id::8-unsigned-big,
      @header_length::8-unsigned-big,
      msg_type::16-unsigned-big,
      0::16-unsigned-big,
      wire_len::32-unsigned-big,
      plain_len::32-unsigned-big,
      req_id::64-unsigned-big
    >>

    {:ok, header <> payload}
  rescue
    e -> {:error, {:encoding_failed, e}}
  end

  @doc """
  Decodes a binary frame into an `%EVoiceKit.Compression.Envelope{}` struct.
  Applies strict frame size, magic, version, algorithm, and length validations.
  """
  @spec decode(binary(), keyword()) :: {:ok, t()} | {:error, atom() | {atom(), term()}}
  def decode(binary, opts \\ [])

  def decode(binary, opts) when is_binary(binary) and byte_size(binary) >= @header_length do
    max_wire = Keyword.get(opts, :max_wire_length, @default_max_wire_length)
    max_plain = Keyword.get(opts, :max_plain_length, @default_max_plain_length)
    max_expansion = Keyword.get(opts, :max_expansion_ratio, @default_max_expansion_ratio)

    case binary do
      <<
        @magic::binary-size(4),
        @version::8-unsigned-big,
        flags::8-unsigned-big,
        algo_id::8-unsigned-big,
        @header_length::8-unsigned-big,
        msg_type::16-unsigned-big,
        0::16-unsigned-big,
        wire_len::32-unsigned-big,
        plain_len::32-unsigned-big,
        req_id::64-unsigned-big,
        payload::binary
      >> ->
        validate_and_build(
          flags,
          algo_id,
          msg_type,
          wire_len,
          plain_len,
          req_id,
          payload,
          max_wire,
          max_plain,
          max_expansion
        )

      <<magic::binary-size(4), _rest::binary>> when magic != @magic ->
        {:error, :invalid_magic}

      <<@magic::binary-size(4), version::8, _rest::binary>> when version != @version ->
        {:error, :unsupported_version}

      <<@magic::binary-size(4), @version::8, _flags::8, _algo::8, header_len::8, _rest::binary>>
      when header_len != @header_length ->
        {:error, :invalid_header_length}

      <<@magic::binary-size(4), @version::8, _flags::8, _algo::8, @header_length::8, _msg::16,
        reserved::16, _rest::binary>>
      when reserved != 0 ->
        {:error, :reserved_bits_not_zero}

      _ ->
        {:error, :malformed_header}
    end
  end

  def decode(binary, _opts) when is_binary(binary), do: {:error, :frame_too_short}
  def decode(_non_binary, _opts), do: {:error, :not_a_binary}

  # --- Internal Helpers ---

  defp validate_and_build(
         flags,
         algo_id,
         msg_type,
         wire_len,
         plain_len,
         req_id,
         payload,
         max_wire,
         max_plain,
         max_expansion
       ) do
    cond do
      (flags &&& 0xFC) != 0 ->
        {:error, :reserved_flags_not_zero}

      byte_size(payload) != wire_len ->
        {:error, :payload_length_mismatch}

      wire_len > max_wire ->
        {:error, :wire_length_exceeded}

      plain_len > max_plain ->
        {:error, :plain_length_exceeded}

      true ->
        compressed? = (flags &&& 0x01) == 0x01
        control? = (flags &&& 0x02) == 0x02

        case id_to_algorithm(algo_id) do
          {:ok, algorithm} ->
            validate_payload_semantics(
              compressed?,
              control?,
              algorithm,
              msg_type,
              wire_len,
              plain_len,
              req_id,
              payload,
              max_expansion
            )

          {:error, _} = err ->
            err
        end
    end
  end

  defp validate_payload_semantics(
         false = _compressed,
         control?,
         :none,
         msg_type,
         wire_len,
         plain_len,
         req_id,
         payload,
         _max_expansion
       ) do
    if wire_len == plain_len do
      {:ok,
       %__MODULE__{
         version: @version,
         compressed: false,
         control: control?,
         algorithm: :none,
         message_type: msg_type,
         plain_length: plain_len,
         request_id: req_id,
         payload: payload
       }}
    else
      {:error, :uncompressed_length_mismatch}
    end
  end

  defp validate_payload_semantics(false, _control, algo, _msg, _wire, _plain, _req, _pay, _exp)
       when algo != :none do
    {:error, :uncompressed_flag_with_non_none_algorithm}
  end

  defp validate_payload_semantics(true, _control, :none, _msg, _wire, _plain, _req, _pay, _exp) do
    {:error, :compressed_flag_with_none_algorithm}
  end

  defp validate_payload_semantics(
         true = _compressed,
         control?,
         algo,
         msg_type,
         wire_len,
         plain_len,
         req_id,
         payload,
         max_expansion
       ) do
    # Prevent decompression bomb: check expansion ratio
    expansion_ratio = if wire_len > 0, do: plain_len / wire_len, else: 1.0

    if expansion_ratio > max_expansion do
      {:error, :expansion_ratio_exceeded}
    else
      {:ok,
       %__MODULE__{
         version: @version,
         compressed: true,
         control: control?,
         algorithm: algo,
         message_type: msg_type,
         plain_length: plain_len,
         request_id: req_id,
         payload: payload
       }}
    end
  end

  defp build_flags(compressed?, control?) do
    c = if compressed?, do: 0x01, else: 0x00
    ctrl = if control?, do: 0x02, else: 0x00
    c ||| ctrl
  end

  defp algorithm_to_id(:none), do: @algo_none
  defp algorithm_to_id(:gzip), do: @algo_gzip
  defp algorithm_to_id(:brotli), do: @algo_brotli
  defp algorithm_to_id(:zstd), do: @algo_zstd
  defp algorithm_to_id(_), do: @algo_none

  defp id_to_algorithm(@algo_none), do: {:ok, :none}
  defp id_to_algorithm(@algo_gzip), do: {:ok, :gzip}
  defp id_to_algorithm(@algo_brotli), do: {:ok, :brotli}
  defp id_to_algorithm(@algo_zstd), do: {:ok, :zstd}
  defp id_to_algorithm(id), do: {:error, {:unknown_algorithm_id, id}}
end
