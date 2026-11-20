defmodule EVoiceKit.SFU.DownTrack do
  @moduledoc """
  Subscriber-specific representation of an egress forwarded media track.
  """

  defstruct [
    :subscriber_sid,
    :track_sid,
    :sink_pid,
    destination_pt: 111,
    destination_ssrc: 0,
    seq_offset: 0,
    ts_offset: 0,
    active: true
  ]

  @type t :: %__MODULE__{
          subscriber_sid: binary(),
          track_sid: binary(),
          sink_pid: pid(),
          destination_pt: non_neg_integer(),
          destination_ssrc: non_neg_integer(),
          seq_offset: integer(),
          ts_offset: integer(),
          active: boolean()
        }

  @spec new(binary(), binary(), pid(), keyword()) :: t()
  def new(subscriber_sid, track_sid, sink_pid, opts \\ []) do
    %__MODULE__{
      subscriber_sid: subscriber_sid,
      track_sid: track_sid,
      sink_pid: sink_pid,
      destination_pt: Keyword.get(opts, :destination_pt, 111),
      destination_ssrc: Keyword.get(opts, :destination_ssrc, :crypto.rand_uniform(10_000, 999_999)),
      seq_offset: Keyword.get(opts, :seq_offset, 0),
      ts_offset: Keyword.get(opts, :ts_offset, 0),
      active: true
    }
  end
end
