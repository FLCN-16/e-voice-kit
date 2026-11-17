defmodule VoiceGateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :voice_gateway,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {VoiceGateway.Application, []}
    ]
  end

  defp deps do
    [
      # Modern, high-performance HTTP & WebSocket server (latest release)
      {:bandit, "~> 1.14"},
      # WebSocket adapter for Plug / Bandit
      {:websock_adapter, "~> 0.7"},
      # Fast HTTP/1.1 and HTTP/2 client with connection pooling
      {:finch, "~> 0.24"},
      # High performance JSON library
      {:jason, "~> 1.4"},
      # High performance MessagePack (used by Fish Audio WebSocket)
      {:msgpax, "~> 2.4"},
      # Outbound WebSocket client (for Deepgram, ElevenLabs, Fish Audio, NestJS bridge)
      {:websockex, "~> 0.5.1"},
      # Telemetry instrumentation
      {:telemetry, "~> 1.4"},
      # CORS support for browser WebSockets
      {:cors_plug, "~> 3.0"}
    ]
  end
end
