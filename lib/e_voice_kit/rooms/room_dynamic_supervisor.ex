defmodule EVoiceKit.Rooms.RoomDynamicSupervisor do
  @moduledoc """
  Dynamic supervisor for spawning and monitoring isolated RoomCoordinator processes.
  """

  use DynamicSupervisor

  alias EVoiceKit.Rooms.RoomCoordinator

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a new room under dynamic supervision.
  """
  def start_room(room_name, opts \\ []) when is_binary(room_name) do
    spec = {RoomCoordinator, {room_name, opts}}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc """
  Stops an active room.
  """
  def stop_room(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
