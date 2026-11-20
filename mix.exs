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
      # Modern, high-performance HTTP & WebSocket server (Bandit 1.15.0)
      {:bandit, "~> 1.15"},
      # WebSocket adapter for Plug / Bandit (0.7.2)
      {:websock_adapter, "~> 0.7"},
      # Fast HTTP/1.1 and HTTP/2 client with connection pooling (0.25.0)
      {:finch, "~> 0.25"},
      # High performance JSON library (1.4.4)
      {:jason, "~> 1.4"},
      # High performance MessagePack (used by Fish Audio WebSocket) (2.4.0)
      {:msgpax, "~> 2.4"},
      # Outbound WebSocket client (for Deepgram, ElevenLabs, Fish Audio, NestJS bridge) (0.5.1)
      {:websockex, "~> 0.5.1"},
      # Telemetry instrumentation (1.4.3)
      {:telemetry, "~> 1.4"},
      # CORS support for browser WebSockets (3.0.3)
      {:cors_plug, "~> 3.0"},

      # Real-Time Media & SFU WebRTC primitives (ExWebRTC 0.18.0)
      {:ex_webrtc, "~> 0.18.0"},
      # WebRTC DataChannels over SCTP (0.1.3, optional - requires Rust build toolchain)
      {:ex_sctp, "~> 0.1.3", optional: true},

      # Application-layer compression codecs (patched against CVEs)
      {:ezstd, "~> 1.2.5"},
      {:brotli, "~> 0.3.4"}
    ]
  end
end
