import Config

if config_env() == :prod or System.get_env("PORT") do
  port = String.to_integer(System.get_env("PORT") || "4000")
  config :e_voice_kit, port: port
end

app_config = [
  # 1. Pipeline Defaults
  default_stt_provider: String.to_atom(System.get_env("DEFAULT_STT_PROVIDER", "deepgram")),
  default_tts_provider: String.to_atom(System.get_env("DEFAULT_TTS_PROVIDER", "elevenlabs")),

  # 2. Conversational Brain Engine
  brain_mode: String.to_atom(System.get_env("BRAIN_MODE", "native")),
  default_llm_provider: String.to_atom(System.get_env("DEFAULT_LLM_PROVIDER", "groq")),
  default_llm_model: System.get_env("DEFAULT_LLM_MODEL", "llama-3.3-70b-versatile"),
  default_system_prompt:
    System.get_env(
      "DEFAULT_SYSTEM_PROMPT",
      "You are a helpful, friendly phone assistant. Keep your responses short and conversational, usually 1 to 2 spoken sentences."
    ),
  default_greeting: System.get_env("DEFAULT_GREETING", "Hello! Thanks for calling. How can I help you today?"),

  # External Bridge IPC (only when BRAIN_MODE=bridge)
  brain_bridge_url: System.get_env("BRAIN_BRIDGE_URL", "ws://localhost:3000/voice-bridge"),

  # 3. LLM Providers
  groq_api_key: System.get_env("GROQ_API_KEY"),
  groq_model: System.get_env("GROQ_MODEL", "llama-3.3-70b-versatile"),

  cerebras_api_key: System.get_env("CEREBRAS_API_KEY"),
  cerebras_model: System.get_env("CEREBRAS_MODEL", "llama3.1-8b"),

  openai_api_key: System.get_env("OPENAI_API_KEY"),
  openai_model: System.get_env("OPENAI_MODEL", "gpt-4o-mini"),

  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  anthropic_model: System.get_env("ANTHROPIC_MODEL", "claude-3-5-haiku-20241022"),

  deepseek_api_key: System.get_env("DEEPSEEK_API_KEY"),
  deepseek_model: System.get_env("DEEPSEEK_MODEL", "deepseek-chat"),

  ollama_base_url: System.get_env("OLLAMA_BASE_URL", "http://localhost:11434/v1"),
  ollama_model: System.get_env("OLLAMA_MODEL", "llama3.1"),

  # 4. Deepgram (STT)
  deepgram_api_key: System.get_env("DEEPGRAM_API_KEY"),
  deepgram_model: System.get_env("DEEPGRAM_MODEL", "nova-2"),
  deepgram_endpointing: System.get_env("DEEPGRAM_ENDPOINTING", "300"),

  # 5. AssemblyAI (STT)
  assemblyai_api_key: System.get_env("ASSEMBLYAI_API_KEY"),
  assemblyai_sample_rate: System.get_env("ASSEMBLYAI_SAMPLE_RATE", "8000"),

  # 6. ElevenLabs (TTS)
  elevenlabs_api_key: System.get_env("ELEVENLABS_API_KEY"),
  elevenlabs_model_id: System.get_env("ELEVENLABS_MODEL_ID", "eleven_turbo_v2_5"),
  elevenlabs_voice_id: System.get_env("ELEVENLABS_VOICE_ID", "21m00Tcm4TlvDq8ikWAM"),
  elevenlabs_output_format: System.get_env("ELEVENLABS_OUTPUT_FORMAT", "ulaw_8000"),

  # 7. Cartesia (TTS)
  cartesia_api_key: System.get_env("CARTESIA_API_KEY"),
  cartesia_model_id: System.get_env("CARTESIA_MODEL_ID", "sonic-english"),
  cartesia_voice_id: System.get_env("CARTESIA_VOICE_ID", "a0e99841-438c-4a64-b679-ae501e7d6091"),

  # 8. Fish Audio (TTS)
  fishaudio_api_key: System.get_env("FISHAUDIO_API_KEY"),
  fishaudio_model: System.get_env("FISHAUDIO_MODEL", "s2.1-pro"),
  fishaudio_voice_id: System.get_env("FISHAUDIO_VOICE_ID"),

  # 9. Sarvam AI (Indic STT & TTS)
  sarvam_api_key: System.get_env("SARVAM_API_KEY"),
  sarvam_stt_model: System.get_env("SARVAM_STT_MODEL", "saaras:v2"),
  sarvam_stt_language: System.get_env("SARVAM_STT_LANGUAGE", "hi-IN"),
  sarvam_tts_model: System.get_env("SARVAM_TTS_MODEL", "bulbul:v2"),
  sarvam_tts_language: System.get_env("SARVAM_TTS_LANGUAGE", "hi-IN"),
  sarvam_tts_speaker: System.get_env("SARVAM_TTS_SPEAKER", "meera")
]

# Set primary config for :e_voice_kit
config :e_voice_kit, app_config
