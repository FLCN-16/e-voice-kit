defmodule EVoiceKit.Participants.Permissions do
  @moduledoc """
  Permission grants and access controls for a participant inside a room.
  """

  defstruct [
    can_publish: true,
    can_subscribe: true,
    can_publish_data: true,
    can_publish_sources: [:microphone, :camera, :screen_share],
    is_admin: false,
    hidden: false
  ]

  @type t :: %__MODULE__{
          can_publish: boolean(),
          can_subscribe: boolean(),
          can_publish_data: boolean(),
          can_publish_sources: [atom()],
          is_admin: boolean(),
          hidden: boolean()
        }

  @doc """
  Constructs permissions from a keyword list or map.
  """
  @spec new(keyword() | map()) :: t()
  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    struct(__MODULE__, opts)
  end

  def new(map) when is_map(map) do
    %__MODULE__{
      can_publish: Map.get(map, "can_publish", Map.get(map, :can_publish, true)),
      can_subscribe: Map.get(map, "can_subscribe", Map.get(map, :can_subscribe, true)),
      can_publish_data: Map.get(map, "can_publish_data", Map.get(map, :can_publish_data, true)),
      is_admin: Map.get(map, "is_admin", Map.get(map, :is_admin, false)),
      hidden: Map.get(map, "hidden", Map.get(map, :hidden, false))
    }
  end
end
