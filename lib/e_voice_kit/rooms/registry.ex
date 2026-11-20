defmodule EVoiceKit.Rooms.Registry do
  @moduledoc """
  Registry for active room coordinators.
  """

  @registry_name __MODULE__

  def child_spec(_opts) do
    Registry.child_spec(
      keys: :unique,
      name: @registry_name
    )
  end

  @doc """
  Generates a via-tuple for registering or locating a RoomCoordinator process by room name.
  """
  def via_tuple(room_name) when is_binary(room_name) do
    {:via, Registry, {@registry_name, room_name}}
  end

  @doc """
  Looks up the pid of a room coordinator by room name.
  """
  @spec lookup(binary()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(room_name) when is_binary(room_name) do
    case Registry.lookup(@registry_name, room_name) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end
