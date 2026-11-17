defmodule EVoiceKit.MixProject do
  use Mix.Project

  def project do
    [
      app: :e_voice_kit,
      version: "1.0.0",
      elixir: "~> 1.15",
      name: "E-Voice-Kit",
      source_url: "https://github.com/FLCN-16/e-voice-kit",
      homepage_url: "https://github.com/FLCN-16/e-voice-kit",
      description: "E-Voice-Kit: Ultra-low-latency, real-time Voice AI edge gateway for telephony and pluggable STT/TTS",
      start_permanent: Mix.env() == :prod,
      releases: [
        e_voice_kit: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent]
        ]
      ],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {EVoiceKit.Application, []}
    ]
  end

  defp deps do
    [
      # Modern, high-performance HTTP & WebSocket server (Bandit)
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
