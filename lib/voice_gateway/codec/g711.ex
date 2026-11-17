defmodule VoiceGateway.Codec.G711 do
  @moduledoc """
  High-performance G.711 μ-law (PCMU, payload 0) and A-law (PCMA, payload 8) audio transcoding.

  Implemented with native Elixir binary pattern matching and standard ITU-T G.711 algorithms.
  Replaces the deprecated Python `audioop` module with zero external C dependencies.
  """

  use Bitwise

  @bias 0x84
  @clip 32635

  # Build 256-element decode lookup table for μ-law at compile time
  @mulaw_decode_table (for byte <- 0..255 do
                         inv = bnot(byte) &&& 0xFF
                         sign = inv &&& 0x80
                         exponent = (inv &&& 0x70) >>> 4
                         mantissa = inv &&& 0x0F

                         sample = (mantissa <<< 3) + @bias
                         sample = sample <<< exponent
                         sample = sample - @bias

                         if sign != 0 do
                           -sample
                         else
                           sample
                         end
                       end
                       |> List.to_tuple())

  # Build 256-element decode lookup table for A-law at compile time
  @alaw_decode_table (for byte <- 0..255 do
                        inv = bxor(byte, 0x55)
                        sign = inv &&& 0x80
                        exponent = (inv &&& 0x70) >>> 4
                        mantissa = inv &&& 0x0F

                        sample =
                          if exponent == 0 do
                            (mantissa <<< 4) + 8
                          else
                            ((mantissa <<< 4) + 0x108) <<< (exponent - 1)
                          end

                        if sign != 0 do
                          sample
                        else
                          -sample
                        end
                      end
                      |> List.to_tuple())

  # ==========================================
  # μ-law (PCMU) API
  # ==========================================

  @doc """
  Decodes a binary of G.711 μ-law (PCMU) 8-bit audio into 16-bit signed linear PCM (little-endian).
  """
  @spec decode_mulaw(binary()) :: binary()
  def decode_mulaw(binary) when is_binary(binary) do
    decode_mulaw_acc(binary, <<>>)
  end

  defp decode_mulaw_acc(<<>>, acc), do: acc

  defp decode_mulaw_acc(<<byte::8, rest::binary>>, acc) do
    sample = elem(@mulaw_decode_table, byte)
    decode_mulaw_acc(rest, <<acc::binary, sample::16-little-signed>>)
  end

  @doc """
  Encodes a binary of 16-bit signed linear PCM (little-endian) into G.711 μ-law (PCMU) 8-bit audio.
  Gracefully handles any incomplete trailing byte.
  """
  @spec encode_mulaw(binary()) :: binary()
  def encode_mulaw(binary) when is_binary(binary) do
    encode_mulaw_acc(binary, <<>>)
  end

  defp encode_mulaw_acc(<<>>, acc), do: acc

  defp encode_mulaw_acc(<<sample::16-little-signed, rest::binary>>, acc) do
    byte = linear_to_mulaw(sample)
    encode_mulaw_acc(rest, <<acc::binary, byte::8>>)
  end

  # Discard incomplete trailing half-sample defensively
  defp encode_mulaw_acc(_trailing_byte, acc), do: acc

  # ITU-T G.711 linear to μ-law byte
  defp linear_to_mulaw(sample) do
    sign = if sample < 0, do: 0x80, else: 0x00
    sample = if sample < 0, do: -sample, else: sample
    sample = min(sample, @clip)
    sample = sample + @bias

    exponent = calculate_exponent(sample)
    mantissa = (sample >>> (exponent + 3)) &&& 0x0F
    ulaw_byte = bnot(sign ||| (exponent <<< 4) ||| mantissa) &&& 0xFF
    ulaw_byte
  end

  defp calculate_exponent(sample) do
    cond do
      sample > 0x3FFF -> 7
      sample > 0x1FFF -> 6
      sample > 0x0FFF -> 5
      sample > 0x07FF -> 4
      sample > 0x03FF -> 3
      sample > 0x01FF -> 2
      sample > 0x00FF -> 1
      true -> 0
    end
  end

  # ==========================================
  # A-law (PCMA) API
  # ==========================================

  @doc """
  Decodes a binary of G.711 A-law (PCMA) 8-bit audio into 16-bit signed linear PCM (little-endian).
  """
  @spec decode_alaw(binary()) :: binary()
  def decode_alaw(binary) when is_binary(binary) do
    decode_alaw_acc(binary, <<>>)
  end

  defp decode_alaw_acc(<<>>, acc), do: acc

  defp decode_alaw_acc(<<byte::8, rest::binary>>, acc) do
    sample = elem(@alaw_decode_table, byte)
    decode_alaw_acc(rest, <<acc::binary, sample::16-little-signed>>)
  end

  @doc """
  Encodes a binary of 16-bit signed linear PCM (little-endian) into G.711 A-law (PCMA) 8-bit audio.
  """
  @spec encode_alaw(binary()) :: binary()
  def encode_alaw(binary) when is_binary(binary) do
    encode_alaw_acc(binary, <<>>)
  end

  defp encode_alaw_acc(<<>>, acc), do: acc

  defp encode_alaw_acc(<<sample::16-little-signed, rest::binary>>, acc) do
    byte = linear_to_alaw(sample)
    encode_alaw_acc(rest, <<acc::binary, byte::8>>)
  end

  defp encode_alaw_acc(_trailing_byte, acc), do: acc

  defp linear_to_alaw(sample) do
    sign = if sample < 0, do: 0x00, else: 0x80
    sample = if sample < 0, do: -sample, else: sample
    sample = min(sample, @clip)

    {exponent, mantissa} =
      cond do
        sample >= 0x4000 -> {7, (sample >>> 10) &&& 0x0F}
        sample >= 0x2000 -> {6, (sample >>> 9) &&& 0x0F}
        sample >= 0x1000 -> {5, (sample >>> 8) &&& 0x0F}
        sample >= 0x0800 -> {4, (sample >>> 7) &&& 0x0F}
        sample >= 0x0400 -> {3, (sample >>> 6) &&& 0x0F}
        sample >= 0x0200 -> {2, (sample >>> 5) &&& 0x0F}
        sample >= 0x0100 -> {1, (sample >>> 4) &&& 0x0F}
        true -> {0, (sample >>> 4) &&& 0x0F}
      end

    alaw_byte = bxor(sign ||| (exponent <<< 4) ||| mantissa, 0x55) &&& 0xFF
    alaw_byte
  end

  @doc """
  Creates silence frames for G.711 μ-law. In μ-law, 0xFF represents digital silence.
  """
  @spec silence_mulaw(non_neg_integer()) :: binary()
  def silence_mulaw(num_bytes) when is_integer(num_bytes) and num_bytes >= 0 do
    :binary.copy(<<0xFF>>, num_bytes)
  end

  @doc """
  Creates silence frames for G.711 A-law. In A-law, 0xD5 represents digital silence.
  """
  @spec silence_alaw(non_neg_integer()) :: binary()
  def silence_alaw(num_bytes) when is_integer(num_bytes) and num_bytes >= 0 do
    :binary.copy(<<0xD5>>, num_bytes)
  end
end
