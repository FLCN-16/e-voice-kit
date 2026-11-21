defmodule EVoiceKit.SFU.UpTrack do
  @moduledoc """
  Server representation of an incoming published media track.
  """

  defstruct [
    :track_sid,
    :publisher_sid,
    :kind,
    :codec,
    :clock_rate,
    :payload_type,
    :ssrc,
    subscribers: %{},
    active: true
  ]

  @type kind :: :audio | :video
  @type codec :: :opus | :pcmu | :pcma | :vp8 | :h264
  @type t :: %__MODULE__{
          track_sid: binary(),
          publisher_sid: binary(),
          kind: kind(),
          codec: codec(),
          clock_rate: pos_integer(),
          payload_type: non_neg_integer(),
          ssrc: non_neg_integer() | nil,
          subscribers: map(),
          active: boolean()
        }

  @spec new(binary(), binary(), keyword()) :: t()
  def new(track_sid, publisher_sid, opts \\ []) do
    %__MODULE__{
      track_sid: track_sid,
      publisher_sid: publisher_sid,
      kind: Keyword.get(opts, :kind, :audio),
      codec: Keyword.get(opts, :codec, :opus),
      clock_rate: Keyword.get(opts, :clock_rate, 48000),
      payload_type: Keyword.get(opts, :payload_type, 111),
      ssrc: Keyword.get(opts, :ssrc, 0),
      subscribers: %{},
      active: true
    }
  end
end
