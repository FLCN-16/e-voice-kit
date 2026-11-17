defmodule EVoiceKit.Pipeline.Buffer do
  @moduledoc """
  Audio frame buffer and packetizer for real-time telephony streaming.

  Standard phone audio (8kHz G.711) operates on 20ms packets (160 bytes).
  This buffer accumulates incoming variable-sized chunks and yields 160-byte packets,
  with instant flush capabilities on barge-in.
  """

  defstruct data: <<>>,
            packet_size: 160,
            packets_queued: 0

  @type t :: %__MODULE__{
          data: binary(),
          packet_size: non_neg_integer(),
          packets_queued: non_neg_integer()
        }

  @doc """
  Initializes a new audio buffer. Default packet size is 160 bytes (20ms @ 8kHz G.711).
  """
  def new(packet_size \\ 160) do
    %__MODULE__{packet_size: packet_size, data: <<>>, packets_queued: 0}
  end

  @doc """
  Appends new raw audio bytes to the buffer and pops all complete packets.
  Returns `{packets, updated_buffer}`.
  """
  @spec push(t(), binary()) :: {[binary()], t()}
  def push(%__MODULE__{} = buffer, chunk) when is_binary(chunk) do
    combined = <<buffer.data::binary, chunk::binary>>
    extract_packets(combined, buffer.packet_size, [])
  end

  @doc """
  Instantly discards all buffered audio (used on caller barge-in / interruption).
  """
  @spec flush(t()) :: t()
  def flush(%__MODULE__{packet_size: size}) do
    %__MODULE__{packet_size: size, data: <<>>, packets_queued: 0}
  end

  @doc """
  Returns the byte size of current pending (unpacketized) audio.
  """
  @spec pending_bytes(t()) :: non_neg_integer()
  def pending_bytes(%__MODULE__{data: data}), do: byte_size(data)

  defp extract_packets(data, size, acc) when byte_size(data) >= size do
    <<packet::binary-size(size), rest::binary>> = data
    extract_packets(rest, size, [packet | acc])
  end

  defp extract_packets(remainder, size, acc) do
    packets = Enum.reverse(acc)
    updated_buffer = %__MODULE__{packet_size: size, data: remainder, packets_queued: length(packets)}
    {packets, updated_buffer}
  end
end
