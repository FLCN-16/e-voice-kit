# Pluggable Provider Architecture & Base Classes

VoiceGateway treats speech providers (STT, TTS) and telephony carriers as first-class pluggable abstractions. You can integrate any speech engine, local model (Whisper, Kokoro), or proprietary cloud API in under 40 lines of code by using the **Abstract Base Class macros**:

* `use VoiceGateway.Providers.STT` for Speech-to-Text
* `use VoiceGateway.Providers.TTS` for Text-to-Speech
* `use VoiceGateway.Transports.WebSocketCarrier` for Telephony Carriers

---

## 1. Speech-to-Text (STT) Base Class & Behaviour

### Base Class Macro: `use VoiceGateway.Providers.STT`

When implementing an STT provider, the `VoiceGateway.Providers.STT` macro automatically handles:
1. **WebSockex Connection Management**: Connection lifecycle, extra headers, and automatic reconnects.
2. **Audio Transcoding**: Configure `audio_format: :pcm_16` or `audio_format: :mulaw`. If your provider expects linear PCM, VoiceGateway automatically transcodes 8kHz G.711 μ-law audio to 16-bit linear PCM using compile-time binary lookup tables.
3. **Session Notification**: Dispatches `{:stt_speech_started, call_id}` (barge-in) and `{:stt_transcript, call_id, text, is_final, speech_final}` directly to the active call session.

### Example: Implementing a Custom Whisper STT Client in ~30 Lines

```elixir
defmodule VoiceGateway.Clients.WhisperSTT do
  @moduledoc """
  Streaming STT client for self-hosted Whisper / Faster-Whisper endpoints.
  """

  use VoiceGateway.Providers.STT, audio_format: :pcm_16

  # 1. Build WebSocket URL and authentication headers
  @impl VoiceGateway.Providers.STT
  def build_connection(_call_id, opts) do
    base_url = opts[:url] || "ws://localhost:9000/v1/stream"
    language = opts[:language_code] || "en"
    url = "\#{base_url}?language=\#{language}&sample_rate=8000"
    {:ok, url, [], %{language: language}}
  end

  # 2. Parse inbound WebSocket frames and emit speech events
  @impl VoiceGateway.Providers.STT
  def parse_speech_event({:text, json_str}, state) do
    case Jason.decode(json_str) do
      {:ok, %{"event" => "speech_started"}} ->
        {:speech_started, state}

      {:ok, %{"text" => text, "is_final" => is_final}} ->
        {:transcript, text, is_final, is_final, state}

      _ ->
        :ignore
    end
  end

  def parse_speech_event(_other, _state), do: :ignore

  # 3. Optional: Encode end-of-stream / close frame
  @impl VoiceGateway.Providers.STT
  def encode_close_frame(_state) do
    {:ok, {:text, Jason.encode!(%{"type" => "eof"})}}
  end
end
```

### Built-in STT Providers:
* **Deepgram Nova:** [`VoiceGateway.Clients.DeepgramSTT`](file:///c:/Users/RishabhKumar/Work/openring-main/elixir/lib/voice_gateway/clients/deepgram_stt.ex)
* **AssemblyAI:** [`VoiceGateway.Clients.AssemblyAISTT`](file:///c:/Users/RishabhKumar/Work/openring-main/elixir/lib/voice_gateway/clients/assemblyai_stt.ex)
* **Sarvam AI (Indic):** [`VoiceGateway.Clients.SarvamSTT`](file:///c:/Users/RishabhKumar/Work/openring-main/elixir/lib/voice_gateway/clients/sarvam_stt.ex)
* **Self-Hosted Whisper:** [`VoiceGateway.Clients.WhisperSTT`](file:///c:/Users/RishabhKumar/Work/openring-main/elixir/lib/voice_gateway/clients/whisper_stt.ex)

---

## 2. Text-to-Speech (TTS) Base Class & Behaviour

### Base Class Macro: `use VoiceGateway.Providers.TTS`

When implementing a TTS provider, the `VoiceGateway.Providers.TTS` macro automatically handles:
1. **WebSockex Streaming Protocol**: Cast handling for `stream_text/3` and `abort/1`.
2. **Audio Transcoding**: Configure `audio_format: :pcm_16` or `audio_format: :mulaw`. If the TTS provider outputs linear PCM, the base class automatically converts it to 8kHz G.711 μ-law before piping it to telephony.
3. **Session Routing**: Dispatches `{:tts_audio_chunk, mulaw_chunk}` and `{:tts_turn_completed, call_id}` directly to the caller transport.
4. **Barge-in Abort**: Handles caller barge-in interruptions and dispatches your `encode_abort_frame/1`.

### Example: Implementing an OpenAI Realtime TTS Client in ~40 Lines

```elixir
defmodule VoiceGateway.Clients.OpenAITTS do
  @moduledoc """
  Streaming TTS client for OpenAI Realtime Speech synthesis endpoints.
  """

  use VoiceGateway.Providers.TTS, audio_format: :pcm_16

  # 1. Build WebSocket URL and headers
  @impl VoiceGateway.Providers.TTS
  def build_connection(call_id, opts) do
    api_key = opts[:api_key] || Application.get_env(:voice_gateway, :openai_api_key)
    voice = opts[:voice_id] || "alloy"
    url = "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview"

    headers = [
      {"Authorization", "Bearer \#{api_key}"},
      {"OpenAI-Beta", "realtime=v1"}
    ]

    {:ok, url, headers, %{call_id: call_id, voice: voice}}
  end

  # 2. Encode outbound text chunk into carrier frame
  @impl VoiceGateway.Providers.TTS
  def encode_text_frame(text, _continue?, state) do
    payload = %{
      "type" => "response.create",
      "response" => %{
        "modalities" => ["audio"],
        "instructions" => "Speak the text naturally: \#{text}",
        "voice" => state.provider_state.voice,
        "output_audio_format" => "pcm16"
      }
    }

    {:reply, {:text, Jason.encode!(payload)}, state}
  end

  # 3. Parse inbound audio chunks and completion signals
  @impl VoiceGateway.Providers.TTS
  def parse_audio_event({:text, json_str}, state) do
    case Jason.decode(json_str) do
      {:ok, %{"type" => "response.audio.delta", "delta" => b64_pcm}} ->
        case Base.decode64(b64_pcm) do
          {:ok, pcm_bytes} -> {:audio, pcm_bytes, state}
          :error -> :ignore
        end

      {:ok, %{"type" => "response.audio.done"}} ->
        {:turn_completed, state}

      _ ->
        :ignore
    end
  end

  def parse_audio_event(_other, _state), do: :ignore

  # 4. Instant abort on caller barge-in
  @impl VoiceGateway.Providers.TTS
  def encode_abort_frame(state) do
    cancel_payload = %{"type" => "response.cancel"}
    {:reply, {:text, Jason.encode!(cancel_payload)}, state}
  end
end
```

### Built-in TTS Providers:
* **Cartesia Sonic:** [`VoiceGateway.Clients.CartesiaTTS`](file:///c:/Users/RishabhKumar/Work/openring-main/elixir/lib/voice_gateway/clients/cartesia_tts.ex)
* **ElevenLabs:** [`VoiceGateway.Clients.ElevenLabsTTS`](file:///c:/Users/RishabhKumar/Work/openring-main/elixir/lib/voice_gateway/clients/elevenlabs_tts.ex)
* **Fish Audio:** [`VoiceGateway.Clients.FishAudioTTS`](file:///c:/Users/RishabhKumar/Work/openring-main/elixir/lib/voice_gateway/clients/fishaudio_tts.ex)
* **Sarvam AI (Indic):** [`VoiceGateway.Clients.SarvamTTS`](file:///c:/Users/RishabhKumar/Work/openring-main/elixir/lib/voice_gateway/clients/sarvam_tts.ex)
* **OpenAI Realtime TTS:** [`VoiceGateway.Clients.OpenAITTS`](file:///c:/Users/RishabhKumar/Work/openring-main/elixir/lib/voice_gateway/clients/openai_tts.ex)

---

## 3. Telephony Carrier Pluggability

### Base Class: `use VoiceGateway.Transports.WebSocketCarrier`
Telephony carriers (Twilio, Telnyx, Vonage, Plivo, direct SIP) can be plugged in by using the `WebSocketCarrier` macro or implementing `VoiceGateway.Providers.Carrier`:

* **Base Class Macro**: `use VoiceGateway.Transports.WebSocketCarrier` handles all `WebSock` protocol compliance, session supervision, audio forwarding, and barge-in flushing.
* **Built-in Transports**:
  * **Twilio:** [`VoiceGateway.Transports.TwilioWebSocket`](file:///c:/Users/RishabhKumar/Work/openring-main/elixir/lib/voice_gateway/transports/twilio_websocket.ex)
  * **Telnyx:** [`VoiceGateway.Transports.TelnyxWebSocket`](file:///c:/Users/RishabhKumar/Work/openring-main/elixir/lib/voice_gateway/transports/telnyx_websocket.ex)
  * **Vonage:** [`VoiceGateway.Transports.VonageWebSocket`](file:///c:/Users/RishabhKumar/Work/openring-main/elixir/lib/voice_gateway/transports/vonage_websocket.ex)
  * **SIP/RTP:** [`VoiceGateway.Transports.SIPCarrier`](file:///c:/Users/RishabhKumar/Work/openring-main/elixir/lib/voice_gateway/transports/sip_carrier.ex)

> For full implementation details and a 5-minute carrier tutorial, see [**`carrier-transports.md`**](carrier-transports.md).

---

## 4. Canonical Event Enums & Automatic Vendor Normalization

Telephony Voice AI relies on deterministic, sub-50ms barge-in and precise turn completion. However, speech vendors use wildly different naming conventions for the same semantic events.

`VoiceGateway.Providers.Events` provides canonical event enums and **automatic bidirectional normalization**:

### STT Canonical Events (`VoiceGateway.Providers.Events.normalize_stt_event/1`)

| Vendor Event String | Resolves To Canonical Enum | System Action |
| :--- | :--- | :--- |
| `"SpeechStarted"` (Deepgram) | `:speech_started` | Instantly halts active agent speech & flushes carrier audio queue |
| `"vad_started"` (Whisper) | `:speech_started` | Same as above |
| `"input_audio_buffer.speech_started"` (OpenAI) | `:speech_started` | Same as above |
| `"PartialTranscript"` (AssemblyAI) | `:speech_started` | Same as above |
| `"speech_detected"` (Sarvam) | `:speech_started` | Same as above |
| `"SpeechEnded"` / `"utterance_end"` | `:speech_ended` | Silence onset detected |
| `"transcript"` (any) | `{:transcript, text, is_final, speech_final}` | Forwards speech transcript to Agent Brain |

### TTS Canonical Events (`VoiceGateway.Providers.Events.normalize_tts_event/1`)

| Vendor Event String | Resolves To Canonical Enum | System Action |
| :--- | :--- | :--- |
| `"done"` (Cartesia) | `:turn_completed` | Marks agent speech turn complete, resumes caller listening |
| `"response.audio.done"` (OpenAI) | `:turn_completed` | Same as above |
| `"is_final"` (ElevenLabs) | `:turn_completed` | Same as above |
| `"complete"` / `"playback_completed"` | `:turn_completed` | Same as above |
| `"canceled"` / `"response.cancel"` | `:turn_aborted` | Acknowledges barge-in cancellation |

### How Providers Use This:
When creating a custom provider with `use VoiceGateway.Providers.STT` or `use VoiceGateway.Providers.TTS`, your `parse_speech_event` or `parse_audio_event` can return **either**:
1. The canonical atom: `{:speech_started, state}` or `{:turn_completed, state}`
2. The raw vendor string/event: `{"vad_started", state}` or `{"done", state}`

The base class automatically runs it through `Events.normalize_stt_event/1` or `Events.normalize_tts_event/1` to ensure every provider behaves identically across the entire platform.

---

## 5. Registering Custom Providers

To plug in a custom provider, declare it in your `config/config.exs`:

```elixir
config :voice_gateway, :stt_providers, %{
  my_custom_stt: MyCompany.CustomSTT,
  whisper: VoiceGateway.Clients.WhisperSTT
}

config :voice_gateway, :tts_providers, %{
  my_custom_tts: MyCompany.CustomTTS,
  openai: VoiceGateway.Clients.OpenAITTS
}
```

Calls can now request `stt_provider: :whisper` or `tts_provider: :openai` dynamically.
