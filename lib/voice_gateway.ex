defmodule VoiceGateway do
  @moduledoc """
  VoiceGateway is the ultra-low-latency real-time voice edge for the omnichannel AI platform.

  Responsibilities:
  - Telephony ingress via WebSockets (Twilio, Telnyx) and SIP/RTP
  - G.711 μ-law / A-law audio transcoding via binary pattern matching
  - Streaming STT (Deepgram) with cloud VAD
  - Streaming TTS (Cartesia / ElevenLabs / Fish Audio)
  - Duplex IPC to NestJS Cognitive Brain (`/voice-bridge`)
  - Sub-50ms barge-in and audio flush
  """

  @doc """
  Returns the count of currently active call sessions.
  """
  def active_calls_count do
    DynamicSupervisor.which_children(VoiceGateway.Pipeline.SessionSupervisor)
    |> length()
  end

  @doc """
  Looks up a call session process by its call_id.
  """
  def get_session(call_id) do
    case Registry.lookup(VoiceGateway.SessionRegistry, call_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Dynamically reconfigures an active call's STT/TTS providers, models, languages,
  voices, or speakers on the fly without dropping the telephony connection.

  ## Examples

      VoiceGateway.reconfigure_call("call_123", %{
        "stt_provider" => "sarvam",
        "tts_provider" => "sarvam",
        "language_code" => "hi-IN",
        "speaker" => "meera"
      })
  """
  def reconfigure_call(call_id, new_config) do
    VoiceGateway.Pipeline.Session.reconfigure(call_id, new_config)
  end
end
