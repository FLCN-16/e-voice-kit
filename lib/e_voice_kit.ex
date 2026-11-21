defmodule EVoiceKit do
  @moduledoc """
  EVoiceKit (E-Voice-Kit) is the ultra-low-latency, real-time Voice AI edge gateway for telephony and conversational AI.

  Responsibilities:
  - Telephony ingress via WebSockets (Twilio, Telnyx, Vonage) and SIP/RTP
  - G.711 μ-law / A-law audio transcoding via binary pattern matching
  - Streaming STT (Deepgram, AssemblyAI, Sarvam, Whisper) with cloud VAD
  - Streaming TTS (Cartesia, ElevenLabs, Fish Audio, Sarvam, OpenAI)
  - Native conversational LLM Brain (Groq, Cerebras, OpenAI, Anthropic, DeepSeek, Ollama)
  - Duplex IPC to external brains (`/voice-bridge`)
  - Sub-50ms barge-in and audio flush
  """

  @doc """
  Returns the count of currently active call sessions.
  """
  def active_calls_count do
    DynamicSupervisor.which_children(EVoiceKit.Pipeline.SessionSupervisor)
    |> length()
  end

  @doc """
  Looks up a call session process by its call_id.
  """
  def get_session(call_id) do
    case Registry.lookup(EVoiceKit.SessionRegistry, call_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Dynamically reconfigures an active call's STT/TTS providers, models, languages,
  voices, or speakers on the fly without dropping the telephony connection.

  ## Examples

      EVoiceKit.reconfigure_call("call_123", %{
        "stt_provider" => "sarvam",
        "tts_provider" => "sarvam",
        "language_code" => "hi-IN",
        "speaker" => "meera"
      })
  """
  def reconfigure_call(call_id, new_config) do
    EVoiceKit.Pipeline.Session.reconfigure(call_id, new_config)
  end

  # --- Real-Time SFU & Room Management ---

  @doc """
  Starts or retrieves an active WebRTC room coordinator.
  """
  def start_room(room_name, opts \\ []) do
    case EVoiceKit.Rooms.RoomDynamicSupervisor.start_room(room_name, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      err -> err
    end
  end

  @doc """
  Looks up an active room coordinator by room name.
  """
  def get_room(room_name) do
    EVoiceKit.Rooms.Registry.lookup(room_name)
  end

  @doc """
  Returns the count of active room coordinators under dynamic supervision.
  """
  def active_rooms_count do
    DynamicSupervisor.which_children(EVoiceKit.Rooms.RoomDynamicSupervisor)
    |> length()
  end
end
