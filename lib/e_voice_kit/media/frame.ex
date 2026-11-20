defmodule EVoiceKit.Media.Frame do
  @moduledoc """
  Media-independent audio/video frame structure bridging telephony, WebRTC, and Voice AI STT/TTS pipelines.

  See `docs/ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md` (Section 18).
  """

  defstruct [
    :track_sid,
    :data,
    format: :pcm,
    sample_rate: 48000,
    channels: 1,
    samples: 0,
    timestamp: 0
  ]

  @type format :: :pcm | :opus | :g711_ulaw | :g711_alaw | :vp8 | :h264
  @type t :: %__MODULE__{
          track_sid: binary() | nil,
          format: format(),
          sample_rate: pos_integer(),
          channels: pos_integer(),
          samples: non_neg_integer(),
          timestamp: non_neg_integer(),
          data: binary()
        }

  @doc """
  Constructs a standard PCM audio frame.
  """
  def pcm(data, sample_rate \\ 48000, channels \\ 1) do
    # 16-bit PCM = 2 bytes per sample per channel
    samples = div(byte_size(data), 2 * channels)

    %__MODULE__{
      format: :pcm,
      sample_rate: sample_rate,
      channels: channels,
      samples: samples,
      timestamp: System.system_time(:millisecond),
      data: data
    }
  end

  @doc """
  Constructs an Opus encoded audio frame.
  """
  def opus(data, samples \\ 960) do
    %__MODULE__{
      format: :opus,
      sample_rate: 48000,
      channels: 1,
      samples: samples,
      timestamp: System.system_time(:millisecond),
      data: data
    }
  end
end
