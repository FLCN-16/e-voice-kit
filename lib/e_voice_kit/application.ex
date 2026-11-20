defmodule EVoiceKit.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:e_voice_kit, :port) || Application.get_env(:e_voice_kit, :port, 4000)

    children = [
      # Unique registry for active call sessions
      {Registry, keys: :unique, name: EVoiceKit.SessionRegistry},

      # Native WebRTC SFU Room Registry & Dynamic Supervisor
      EVoiceKit.Rooms.Registry,
      EVoiceKit.Rooms.RoomDynamicSupervisor,

      # HTTP Client with connection pooling for outbound API requests
      {Finch, name: EVoiceKit.Finch},

      # Task Supervisor for async background tasks and speech streams
      {Task.Supervisor, name: EVoiceKit.TaskSupervisor},

      # Dynamic Supervisor for per-call Session GenServers
      EVoiceKit.Pipeline.SessionSupervisor,

      # High-performance Bandit HTTP and WebSocket server
      {Bandit, plug: EVoiceKit.Endpoint, port: port}
    ]

    Logger.info("Starting E-Voice-Kit server on port #{port}")

    opts = [strategy: :one_for_one, name: EVoiceKit.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
