defmodule EVoiceKit.Pipeline.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor managing all active call session GenServers.

  Provides complete fault isolation: if one call crashes, it terminates cleanly
  without affecting any of the hundreds or thousands of other live calls.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a supervised call session under this supervisor.
  """
  def start_session(opts) do
    spec = {EVoiceKit.Pipeline.Session, opts}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc """
  Terminates an active call session.
  """
  def stop_session(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
