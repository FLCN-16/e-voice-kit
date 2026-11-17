# VoiceGateway (Elixir / BEAM)

The ultra-low-latency, 100% pure Elixir real-time Voice AI platform.

Built on the Erlang BEAM virtual machine, VoiceGateway delivers sub-800ms turn latency, sub-50ms barge-in interruptions, and handles tens of thousands of concurrent telephone calls on a single node.

It can run as a **completely self-contained, standalone Voice AI agent** (with built-in streaming LLM inference, sentence chunking, tool calling, and speech processing) or connect to an external microservice backend via duplex WebSocket IPC.

---

## Supported Providers

### 1. Conversational LLMs (`VoiceGateway.LLM.Agent`)
* **Groq** (`:groq`): Ultra-low-latency Llama-3.3-70B inference (~150ms TTFT).
* **Cerebras** (`:cerebras`): High-speed Llama-3.1-8B/70B inference.
* **OpenAI** (`:openai`): GPT-4o and GPT-4o-mini with streaming function calling.
* **Anthropic** (`:anthropic`): Claude 3.5 Sonnet and Haiku via HTTP/2 SSE.
* **DeepSeek** (`:deepseek`): DeepSeek-V3 chat completions.
* **Ollama & vLLM** (`:ollama`): Self-hosted open-weights models.

### 2. Speech-to-Text (STT)
* **Deepgram Nova-2 / Nova-3** (`:deepgram`): High-accuracy streaming WebSocket with built-in Cloud VAD and interim results.
* **AssemblyAI Universal-2** (`:assemblyai`): Real-time streaming WebSocket STT with automatic speech detection and partial transcript barge-in.
* **Sarvam AI Saaras** (`:sarvam`): State-of-the-art streaming ASR for 10+ Indian languages (Hindi, Tamil, Telugu, Kannada, Bengali, Marathi, Gujarati, etc.).
* **Self-Hosted Whisper** (`:whisper`): Faster-Whisper streaming endpoint with automatic 16-bit PCM transcoding.

### 3. Text-to-Speech (TTS)
* **ElevenLabs** (`:elevenlabs`): Turbo v2.5 & Dialogue WebSocket streaming with native `ulaw_8000` telephony output (zero local transcoding).
* **Cartesia Sonic** (`:cartesia`): Ultra-low-latency (<100ms) WebSocket streaming with native μ-law output.
* **Fish Audio** (`:fishaudio`): High-naturalness `s2.1-pro` model with HTTP/2 chunked transfer and real-time PCM transcoding.
* **Sarvam AI Bulbul** (`:sarvam`): Ultra-low-latency streaming TTS for Indic languages (`hi-IN`, `ta-IN`, `te-IN`, `kn-IN`, etc.).
* **OpenAI Realtime TTS** (`:openai`): Low-latency streaming speech synthesis via OpenAI Realtime protocol.

---

## Architecture Overview

```
Telephony (Twilio / Telnyx / SIP)
          │  (WebSocket G.711 μ-law)
          ▼
   VoiceGateway.Endpoint
          │
          ▼
VoiceGateway.Transports.TwilioWebSocket / TelnyxWebSocket
          │
          ▼ (dynamic spawn per call)
VoiceGateway.Pipeline.Session (GenServer per live call)
    ├── Clients.STTStreamer (Pluggable STT Dispatcher)
    │     ├── Clients.DeepgramSTT
    │     ├── Clients.AssemblyAISTT
    │     └── Clients.SarvamSTT
    ├── LLM.Agent (Built-in Pure Elixir Conversational Brain)
    │     ├── Task (Finch HTTP/2 SSE Streaming)
    │     ├── LLM.SentenceChunker (Clause & Sentence Tokenizer)
    │     └── LLM.Tools (Concurrent Function Calling & Telephony Actions)
    ├── Clients.TTSStreamer (Pluggable TTS Dispatcher)
    │     ├── Clients.Cartesia
    │     ├── Clients.ElevenLabsTTS
    │     ├── Clients.FishAudioTTS
    │     └── Clients.SarvamTTS
    └── Clients.BrainBridge (Optional Duplex IPC for external backends)
```

### Key Modules:
* **`VoiceGateway.Codec.G711`**: Native Elixir binary pattern-matching decoder/encoder for 8kHz μ-law (PCMU) to 16-bit linear PCM. Zero external C dependencies.
* **`VoiceGateway.Pipeline.Session`**: State machine managing turn boundaries, conversational fillers, and sub-50ms barge-in interruptions.
* **`VoiceGateway.Pipeline.Buffer`**: Frame packetizer for 20ms (160-byte) audio streaming with instant flush capabilities.
* **`VoiceGateway.Transports.TwilioWebSocket`**: Inbound WebSocket handler compatible with Twilio Media Streams.
* **`VoiceGateway.Transports.TelnyxWebSocket`**: Inbound WebSocket handler compatible with Telnyx Media Streams.
* **`VoiceGateway.Clients.BrainBridge`**: Duplex WebSocket bridge communicating with the NestJS LangChain Agent.

> For the complete Knowledge Base (RAG) specification, see [**`KNOWLEDGE_BASE_INTEGRATION.md`**](file:///c:/Users/RishabhKumar/Work/openring-main/KNOWLEDGE_BASE_INTEGRATION.md).

---

## Latest Packages Used (`mix.exs`)
* **Bandit** (`~> 1.14`): Modern, high-performance HTTP/1.1, HTTP/2, and WebSocket server.
* **WebSockAdapter** (`~> 0.7`): WebSocket adapter for Plug and Bandit.
* **Finch** (`~> 0.24`): High-throughput HTTP client with connection pooling.
* **WebSockex** (`~> 0.5.1`): Outbound WebSocket client for external real-time speech APIs.
* **Jason** (`~> 1.4`): Optimized JSON parser.
* **Msgpax** (`~> 2.4`): High-performance MessagePack codec.
* **Telemetry** (`~> 1.4`): Performance monitoring & metrics.
* **CorsPlug** (`~> 3.0`): CORS middleware for browser clients.

---

## Getting Started

### Configuration
Copy `.env.example` to `.env` and fill in your keys:
```bash
cp .env.example .env
```

Set your default providers:
```env
DEFAULT_STT_PROVIDER=deepgram    # deepgram | assemblyai | sarvam
DEFAULT_TTS_PROVIDER=elevenlabs  # elevenlabs | cartesia | fishaudio | sarvam
```

### Running Locally
```bash
# Fetch dependencies
mix deps.get

# Run tests
mix test

# Start the interactive development server
iex -S mix
```

The gateway listens on `http://localhost:4000`.

### Health Check
```bash
curl http://localhost:4000/health
# {"active_calls":0,"status":"healthy","timestamp":1731744000}
```

---

## Telephony Webhook Configuration

### Twilio
Point your Twilio phone number webhook (Voice URL) to:
```
POST https://your-domain.com/twiml
```
This returns the TwiML to establish a bi-directional media stream to `wss://your-domain.com/media/twilio`.

---

## Running with Docker
```bash
docker build -t voice_gateway .
docker run -p 4000:4000 --env-file .env voice_gateway
```

---

## Dynamic On-the-Go Reconfiguration (Per-Call & Mid-Call Hot Swap)

VoiceGateway supports dynamically configuring or changing STT/TTS providers, models, languages, and voices at any time **without dropping the call**.

### 1. Per-Call Configuration at Ingress (Twilio / Telnyx)
Specify call-specific providers directly in your TwiML `<Parameter>` tags:
```xml
<Response>
  <Connect>
    <Stream url="wss://your-domain.com/media/twilio">
      <Parameter name="stt_provider" value="sarvam" />
      <Parameter name="tts_provider" value="sarvam" />
      <Parameter name="language" value="hi-IN" />
      <Parameter name="speaker" value="meera" />
    </Stream>
  </Connect>
</Response>
```

### 2. Mid-Call Hot-Swap via NestJS Brain Bridge
When a caller requests a language or persona change (e.g. *"Can you speak in Hindi?"*), the NestJS agent emits an in-band WebSocket reconfigure event:
```json
{
  "event": "reconfigure",
  "stt_provider": "sarvam",
  "tts_provider": "sarvam",
  "language_code": "hi-IN",
  "speaker": "meera"
}
```
The call session terminates the previous STT/TTS child clients and launches the new ones in **< 50ms**, while telephony audio continues uninterrupted.

### 3. Mid-Call Hot-Swap via REST API
```bash
curl -X POST http://localhost:4000/calls/MZ12345/reconfigure \
  -H "Content-Type: application/json" \
  -d '{
    "tts_provider": "elevenlabs",
    "voice_id": "21m00Tcm4TlvDq8ikWAM",
    "stt_provider": "deepgram"
  }'
```

### 4. Programmatic Elixir API
```elixir
VoiceGateway.reconfigure_call("call_stream_id", %{
  "tts_provider" => "fishaudio",
  "model_id" => "s2.1-pro"
})
```

---

## Multi-Tenant Ingress & Agent Routing

VoiceGateway resolves multi-tenancy and assistant configuration across all channels:

1. **Telephony Ingress (Twilio / Telnyx):**
   * Uses Dialed Number Identification Service (DNIS): `To` dialed phone number maps to tenant and assistant in PostgreSQL.
   * `POST /twiml` injects `tenant_id` and `assistant_id` as `<Parameter>` tags into the media stream.

2. **Direct SIP Trunks (RFC 3261):**
   * SIP URI matching (`sip:+18005550199@gateway.domain.com`) or custom SIP headers (`X-Tenant-Id: tenant_acme`).

3. **Web / In-App Browser Calls:**
   * Ephemeral signed JWT tokens passed via query string: `wss://gateway.domain.com/media/web?token=eyJhbGci...`.

4. **NestJS Brain Bridge Handshake:**
   * Elixir opens `/voice-bridge?tenant_id=...&assistant_id=...&call_id=...`.
   * NestJS returns the assistant's system prompt, tools, voice provider, and greeting in the initial handshake payload.

---

## 📚 Documentation Suite

Comprehensive guides are available in the [`docs/`](docs/) directory:

* [**Pluggable Carrier Transports & Base Class**](docs/carrier-transports.md): How to use `VoiceGateway.Transports.WebSocketCarrier` to implement new carriers (Twilio, Telnyx, Vonage, SIP) in minutes.
* [**Native Pure Elixir LLM Agent**](docs/native-llm-agent.md): In-depth guide to the pure Elixir LLM engine, sentence chunking, fillers, and tool execution.
* [**System Overview**](docs/overview.md): High-level feature set and why Elixir on BEAM is ideal for voice AI.
* [**Architecture & Supervision**](docs/architecture.md): Deep dive into OTP supervision trees, GenServer lifecycle, and fault isolation.
* [**Pluggable Providers Guide**](docs/pluggable-providers.md): Specification for the `VoiceGateway.Providers.STT` and `VoiceGateway.Providers.TTS` behaviours and how to author custom providers.
* [**Telephony Setup Guide**](docs/telephony-setup.md): Step-by-step guides for connecting Twilio, Telnyx, and direct SIP/RTP trunks.
* [**Dynamic Reconfiguration**](docs/dynamic-reconfiguration.md): Guide to hot-swapping voices, models, and languages on the fly without dropping calls.
* [**Knowledge Base Integration Guide**](../KNOWLEDGE_BASE_INTEGRATION.md): RAG design with `pgvector` HNSW search and conversational fillers.

---

## 🤝 Contributing

We welcome contributions from the open-source community! Please see our [**Contributing Guide**](CONTRIBUTING.md) for details on setting up your local environment, code conventions, and submitting Pull Requests.

---

## 📄 License

VoiceGateway is open-source software licensed under the [**MIT License**](LICENSE).
