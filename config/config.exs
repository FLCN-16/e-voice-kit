import Config

config :voice_gateway,
  port: 4000,
  brain_bridge_url: "ws://localhost:3000/voice-bridge",
  default_stt_provider: :deepgram,
  default_tts_provider: :cartesia

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :call_id]

import_config "#{config_env()}.exs"
