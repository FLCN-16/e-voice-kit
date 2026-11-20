defmodule EVoiceKit.Participants.Participant do
  @moduledoc """
  Data model representing an active participant in a room.
  """

  alias EVoiceKit.Participants.Permissions

  defstruct [
    :participant_sid,
    :identity,
    :name,
    :session_pid,
    :peer_connection_pid,
    permissions: %Permissions{},
    tracks: %{},
    state: :joining,
    joined_at: 0,
    metadata: %{}
  ]

  @type state :: :joining | :connected | :reconnecting | :disconnected
  @type t :: %__MODULE__{
          participant_sid: binary(),
          identity: binary(),
          name: binary(),
          session_pid: pid() | nil,
          peer_connection_pid: pid() | nil,
          permissions: Permissions.t(),
          tracks: map(),
          state: state(),
          joined_at: non_neg_integer(),
          metadata: map()
        }

  @spec new(binary(), keyword()) :: t()
  def new(identity, opts \\ []) do
    %__MODULE__{
      participant_sid: Keyword.get(opts, :participant_sid, generate_sid("PA_")),
      identity: identity,
      name: Keyword.get(opts, :name, identity),
      session_pid: Keyword.get(opts, :session_pid),
      peer_connection_pid: Keyword.get(opts, :peer_connection_pid),
      permissions: Keyword.get(opts, :permissions, %Permissions{}),
      tracks: %{},
      state: :joining,
      joined_at: System.system_time(:second),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp generate_sid(prefix) do
    prefix <> (:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower))
  end
end
