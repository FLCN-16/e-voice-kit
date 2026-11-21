defmodule EVoiceKit.Rooms.Registry do
  @moduledoc """
  Registry for active room coordinators. Room keys are tenant-scoped so two tenants
  may safely use the same human-readable room name.
  """

  @registry_name __MODULE__

  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: @registry_name)
  end

  def room_key(tenant_id, room_name) when is_binary(tenant_id) and is_binary(room_name) do
    :erlang.term_to_binary({tenant_id, room_name})
    |> Base.url_encode64(padding: false)
  end

  def via_tuple(room_name) when is_binary(room_name), do: via_tuple("default", room_name)

  def via_tuple(tenant_id, room_name)
      when is_binary(tenant_id) and is_binary(room_name) do
    {:via, Registry, {@registry_name, room_key(tenant_id, room_name)}}
  end

  def lookup(room_name) when is_binary(room_name), do: lookup("default", room_name)

  def lookup(tenant_id, room_name)
      when is_binary(tenant_id) and is_binary(room_name) do
    case Registry.lookup(@registry_name, room_key(tenant_id, room_name)) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end
