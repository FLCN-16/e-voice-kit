defmodule VoiceGateway.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:voice_gateway, :port, 4000)

    children = [
      # Unique registry for active call sessions
      {Registry, keys: :unique, name: VoiceGateway.SessionRegistry},

      # HTTP Client with connection pooling for outbound API requests
      {Finch, name: VoiceGateway.Finch},

      # Task Supervisor for async background tasks and speech streams
      {Task.Supervisor, name: VoiceGateway.TaskSupervisor},

      # Dynamic Supervisor for per-call Session GenServers
      VoiceGateway.Pipeline.SessionSupervisor,

      # High-performance Bandit HTTP and WebSocket server
      {Bandit, plug: VoiceGateway.Endpoint, port: port}
    ]

    Logger.info("Starting VoiceGateway server on port #{port}")

    opts = [strategy: :one_for_one, name: VoiceGateway.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
