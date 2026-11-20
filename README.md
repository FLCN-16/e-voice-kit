<div align="center">

# E-Voice-Kit

### Ultra-Low-Latency Real-Time WebRTC Media Server & Voice AI Gateway for Elixir / BEAM

[![CI](https://github.com/FLCN-16/e-voice-kit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/FLCN-16/e-voice-kit/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/badge/hex.pm-v1.0.0-blue.svg)](https://hex.pm/packages/e_voice_kit)
[![Elixir](https://img.shields.io/badge/Elixir-~%3E%201.15-purple.svg)](https://elixir-lang.org/)
[![Erlang/OTP](https://img.shields.io/badge/Erlang%2FOTP-26%20%7C%2027-red.svg)](https://www.erlang.org/)
[![WebRTC](https://img.shields.io/badge/WebRTC-ExWebRTC%200.18-blue.svg)](https://hex.pm/packages/ex_webrtc)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

<p align="center">
  A high-performance real-time media server and conversational Voice AI edge gateway built on the Erlang BEAM virtual machine. Combines a native Selective Forwarding Unit (SFU) with sub-50ms barge-in interruptions, directional application compression, WebRTC DataChannels, and carrier-grade telephony ingress.
</p>

</div>

---

## Implementation Status & Core Capabilities

| Capability | Module Namespace | Status | Details |
| :--- | :--- | :--- | :--- |
| **WebRTC PeerConnection Media** | `EVoiceKit.RTC.PeerConnectionOwner` | **Active / Implemented** | Native ExWebRTC (0.18.0) Unified Plan, DTLS-SRTP, SDP offer/answer, trickle ICE |
| **Binary Framing & Envelope** | `EVoiceKit.Compression.Envelope` | **Active / Implemented** | Fixed 28-byte `EVK1` header with endianness validation and message type routing |
| **Streaming Bounded Decompression** | `EVoiceKit.Compression.BoundedDecoder` | **Active / Implemented** | Runtime output-capped `:zlib.safeInflate` preventing decompression bomb attacks |
| **Directional Negotiation** | `EVoiceKit.Compression.Negotiation` | **Active / Implemented** | Asymmetric C2S & S2C codec negotiation (`Zstd`, `Brotli`, `Gzip`, `NONE`) |
| **Cryptographic Authentication** | `EVoiceKit.Auth.Token` | **Active / Implemented** | HMAC-SHA256 signed JWT tokens with room, tenant, and permission grants |
| **Supervised Rooms & Isolation** | `EVoiceKit.Rooms.RoomCoordinator` | **Active / Implemented** | DynamicSupervisor isolation, admission control, process monitoring |
| **Concurrent SFU Track Router** | `EVoiceKit.SFU.Router` | **Active / Implemented** | Fast-path ETS route dispatching, SSRC/PT remapping, slow-subscriber isolation |
| **WebRTC DataChannels** | `EVoiceKit.DataChannels.Relay` | *Phase 2 / Experimental* | Optional ExSCTP data relay architecture |
| **SIP Trunk Room Ingress** | `EVoiceKit.SIP.RoomAdapter` | *Phase 2 / In Progress* | G.711 telephony bridge to WebRTC room tracks |
| **Voice AI Room Agent** | `EVoiceKit.VoiceAI.Participant` | *Phase 2 / In Progress* | First-class AI participant subscribing and publishing in room |

---

## Supported Providers

### 1. Conversational LLMs (`EVoiceKit.LLM.Agent`)
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

```text
                                 EVoiceKit.Endpoint
             ┌───────────────────────────┼───────────────────────────┐
             │ (Telephony Media Streams) │ (Native WebRTC Signaling) │ (Connection Auth)
             ▼                           ▼                           ▼
      /media/{carrier}                /rtc/v1                   /rtc/v1/token
             │                           │
             ▼                           ▼
[Telephony Gateway Plane]       [WebRTC SFU Media Plane]
Pipeline.SessionSupervisor      Rooms.RoomDynamicSupervisor
  └── Pipeline.Session            └── Rooms.RoomCoordinator (1 per room)
        ├── STTStreamer                 ├── Signaling.Session (1 per participant)
        │     ├── Deepgram              ├── RTC.PeerConnectionOwner (DTLS-SRTP / ICE)
        │     └── AssemblyAI            ├── SFU.Router (RTP Packet Fan-Out & Rewriting)
        ├── LLM.Agent                   │     ├── UpTrack (Publisher Ingress)
        │     ├── SentenceChunker       │     └── DownTrack (Subscriber Egress)
        │     └── Tools                 ├── DataChannels.Relay (Multiplexed Data)
        └── TTSStreamer                 ├── VoiceAI.Participant (AI Room Participant)
              ├── Cartesia              └── SIP.RoomAdapter (PSTN / SIP Call Leg Bridge)
              └── ElevenLabs
```

### Key Modules

#### Native WebRTC SFU & Real-Time Media Plane
* **`EVoiceKit.Compression.Envelope`**: Fixed 28-byte binary framing protocol (`EVK1`) for signaling multiplexing, length pre-validation, and decompression-bomb protection.
* **`EVoiceKit.Compression.Negotiation`**: Directional capability negotiation for `Zstandard`, `Brotli`, `Gzip`, and `NONE`.
* **`EVoiceKit.Signaling.Session`**: Stateful signaling session managing capability handshakes, authentication, and room attachment.
* **`EVoiceKit.Rooms.RoomCoordinator`**: Multi-party room coordinator managing participant admission, presence, track metadata, and fault-isolated lifecycles.
* **`EVoiceKit.SFU.Router`**: Central selective forwarding unit fanning out RTP packets asynchronously to subscriber DownTracks.
* **`EVoiceKit.SFU.PacketMapper`**: High-performance 12-byte RTP fixed header rewriting and SSRC/PT translation.
* **`EVoiceKit.RTC.PeerConnectionOwner`**: Manages WebRTC PeerConnection state, SDP offer/answer exchange, and ICE candidates.
* **`EVoiceKit.VoiceAI.Participant`**: First-class room participant representation enabling AI agents to subscribe to user audio and publish synthesized speech.
* **`EVoiceKit.SIP.RoomAdapter`**: Bridges external PSTN / SIP trunks directly into multi-party WebRTC rooms.

#### Telephony Gateway & Conversational Brain
* **`EVoiceKit.Codec.G711`**: Native Elixir binary pattern-matching decoder/encoder for 8kHz μ-law (PCMU) to 16-bit linear PCM. Zero external C dependencies.
* **`EVoiceKit.Pipeline.Session`**: State machine managing telephony call turns, conversational fillers, and sub-50ms barge-in interruptions.
* **`EVoiceKit.Pipeline.Buffer`**: Frame packetizer for 20ms (160-byte) audio streaming with instant flush capabilities.
* **`EVoiceKit.Transports.WebSocketCarrier`**: Base carrier implementation for Twilio, Telnyx, and Vonage media streams.
* **`EVoiceKit.Transports.SIPCarrier`**: SIP/RTP carrier trunk handler.
* **`EVoiceKit.Clients.BrainBridge`**: Duplex WebSocket bridge communicating with external LangChain / NestJS agents.

---

## Latest Packages Used (`mix.exs`)
* **Bandit** (`~> 1.15`): Modern, high-performance HTTP/1.1, HTTP/2, and WebSocket server (latest: `1.15.0`).
* **WebSockAdapter** (`~> 0.7`): WebSocket adapter for Plug and Bandit (latest: `0.7.2`).
* **Finch** (`~> 0.25`): High-throughput HTTP client with connection pooling (latest: `0.25.0`).
* **ExWebRTC** (`~> 0.18.0`): WebRTC SFU primitives (ICE, DTLS, SRTP, RTP, RTCP) (latest: `0.18.0`).
* **ExSCTP** (`~> 0.1.3`): Optional WebRTC DataChannel support over SCTP (latest: `0.1.3`).
* **ezstd** (`~> 1.2.5`): High-speed Zstandard compression NIF, security-patched against CVE-2026-119434.
* **brotli** (`~> 0.3.4`): Brotli stream compression NIF, security-patched against EEF-CVE-2026-111497.
* **Jason** (`~> 1.4`): Optimized JSON parser.
* **Msgpax** (`~> 2.4`): High-performance MessagePack codec.
* **WebSockex** (`~> 0.5.1`): Outbound WebSocket client for external real-time speech APIs.
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
DEFAULT_STT_PROVIDER=deepgram    # deepgram | assemblyai | sarvam | whisper
DEFAULT_TTS_PROVIDER=elevenlabs  # elevenlabs | cartesia | fishaudio | sarvam | openai
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
docker build -t e_voice_kit .
docker run -p 4000:4000 --env-file .env e_voice_kit
```

Or using Docker Compose:
```bash
docker compose up -d
```

---

## Dynamic On-the-Go Reconfiguration (Per-Call & Mid-Call Hot Swap)

E-Voice-Kit supports dynamically configuring or changing STT/TTS providers, models, languages, and voices at any time **without dropping the call**.

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

### 2. Mid-Call Hot-Swap via External Brain Bridge
When a caller requests a language or persona change (e.g. *"Can you speak in Hindi?"*), the agent emits an in-band WebSocket reconfigure event:
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
EVoiceKit.reconfigure_call("call_stream_id", %{
  "tts_provider" => "fishaudio",
  "model_id" => "s2.1-pro"
})
```

---

## Multi-Tenant Ingress & Agent Routing

E-Voice-Kit resolves multi-tenancy and assistant configuration across all channels:

1. **Telephony Ingress (Twilio / Telnyx / Vonage):**
   * Uses Dialed Number Identification Service (DNIS): `To` dialed phone number maps to tenant and assistant in PostgreSQL.
   * `POST /twiml` injects `tenant_id` and `assistant_id` as `<Parameter>` tags into the media stream.

2. **Direct SIP Trunks (RFC 3261):**
   * SIP URI matching (`sip:+18005550199@gateway.domain.com`) or custom SIP headers (`X-Tenant-Id: tenant_acme`).

3. **Web / In-App Browser & WebRTC Multi-Party Rooms:**
   * Participants request a short-lived connection ticket: `POST /rtc/v1/token` with `{"room": "room_name", "identity": "user_id"}`.
   * Connect via native WebSocket: `wss://gateway.domain.com/rtc/v1`.
   * Signaling and DataChannels use the 28-byte `EVK1` binary envelope with directional Brotli, Gzip, and Zstandard compression.
   * An interactive test client is available in [`test/fixtures/browser_client.html`](test/fixtures/browser_client.html).

4. **External Brain Bridge Handshake:**
   * Elixir opens `/voice-bridge?tenant_id=...&assistant_id=...&call_id=...`.
   * The brain returns the assistant's system prompt, tools, voice provider, and greeting in the initial handshake payload.

---

## 📚 Documentation Suite

Comprehensive guides and architectural specifications are available in the [`docs/`](docs/) directory:

* [**E-Voice-Kit Real-Time Media Server Plan**](docs/ELIXIR_REALTIME_SERVER_PLAN.md): Implementation plan and active execution backlog for native Elixir SFU real-time communication.
* [**Deep Technical Design & Engineering Reference**](docs/ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md): Comprehensive 37-section architectural reference covering WebRTC, compression, process ownership, and SFU forwarding.
* [**Architecture Decision Records (ADRs)**](docs/adr/README.md): Index and specifications for all 14 accepted architectural decisions (ADR-0001 through ADR-0014).
* [**Pluggable Carrier Transports & Base Class**](docs/carrier-transports.md): How to use `EVoiceKit.Transports.WebSocketCarrier` to implement new carriers (Twilio, Telnyx, Vonage, SIP) in minutes.
* [**Native Pure Elixir LLM Agent**](docs/native-llm-agent.md): In-depth guide to the pure Elixir LLM engine, sentence chunking, fillers, and tool execution.
* [**System Overview**](docs/overview.md): High-level feature set and why Elixir on BEAM is ideal for voice AI.
* [**Architecture & Supervision**](docs/architecture.md): Deep dive into OTP supervision trees, GenServer lifecycle, and fault isolation.
* [**Pluggable Providers Guide**](docs/pluggable-providers.md): Specification for the `EVoiceKit.Providers.STT` and `EVoiceKit.Providers.TTS` base macros and behaviours.
* [**Telephony Setup Guide**](docs/telephony-setup.md): Step-by-step guides for connecting Twilio, Telnyx, Vonage, and direct SIP/RTP trunks.
* [**Dynamic Reconfiguration**](docs/dynamic-reconfiguration.md): Guide to hot-swapping voices, models, and languages on the fly without dropping calls.

---

## 🤝 Contributing

We welcome contributions from the open-source community! Please see our [**Contributing Guide**](CONTRIBUTING.md) for details on setting up your local environment, code conventions, and submitting Pull Requests.

---

## 📄 License

E-Voice-Kit is open-source software licensed under the [**MIT License**](LICENSE).
