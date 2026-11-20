defmodule EVoiceKit.Rooms.Room do
  @moduledoc """
  Data model representing an active real-time communication room.
  """

  defstruct [
    :room_sid,
    :name,
    :tenant_id,
    max_participants: 100,
    empty_timeout: 300,
    metadata: %{},
    creation_time: 0,
    active: true
  ]

  @type t :: %__MODULE__{
          room_sid: binary(),
          name: binary(),
          tenant_id: binary() | nil,
          max_participants: pos_integer(),
          empty_timeout: non_neg_integer(),
          metadata: map(),
          creation_time: non_neg_integer(),
          active: boolean()
        }

  @doc """
  Creates a new Room struct with a unique room_sid and default parameters.
  """
  @spec new(binary(), keyword()) :: t()
  def new(name, opts \\ []) do
    %__MODULE__{
      room_sid: Keyword.get(opts, :room_sid, generate_sid("RM_")),
      name: name,
      tenant_id: Keyword.get(opts, :tenant_id, "default"),
      max_participants: Keyword.get(opts, :max_participants, 100),
      empty_timeout: Keyword.get(opts, :empty_timeout, 300),
      metadata: Keyword.get(opts, :metadata, %{}),
      creation_time: System.system_time(:second),
      active: true
    }
  end

  defp generate_sid(prefix) do
    prefix <> (:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower))
  end
end
