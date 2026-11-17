# E-Voice-Kit Overview

E-Voice-Kit is an open-source, ultra-low-latency real-time voice edge built in Elixir on the Erlang VM (BEAM).

It powers conversational voice AI applications by bridging telephony carriers (Twilio, Telnyx, Vonage, SIP) directly to streaming speech APIs (Deepgram, AssemblyAI, Sarvam, Whisper, ElevenLabs, Cartesia, Fish Audio, OpenAI) and native or external AI agent backends.

---

## 🌟 Why Elixir for Voice AI?

| Challenge in Python / Node | How Elixir on BEAM Solves It |
|---|---|
| **Audio Jitter from Garbage Collection** | **Per-process GC**: Each call session collects garbage independently. Zero global pauses. |
| **GIL / Event Loop Blocking** | **Preemptive Scheduler**: Network packets and audio frames preempt long compute tasks. Zero audio starvation. |
| **Barge-in / Cancellation Complexity** | **One-line process kills**: Stop audio streams instantly with `Process.exit(pid, :kill)` in $< 20\text{ ms}$. |
| **Concurrency Ceiling on cheap hardware** | **Millions of processes**: A 2-core VPS handles **120–150+ concurrent live phone calls**. |
| **Deprecated Codec Libraries (`audioop`)** | **Native Binary Pattern Matching**: High-speed G.711 μ-law/A-law transcoding at C-level performance. |

---

## 📦 What's in the Box?

* **Pluggable Speech Engine:** Built-in support for Deepgram, AssemblyAI, Sarvam AI, Whisper, ElevenLabs, Cartesia, Fish Audio, and OpenAI.
* **Carrier Integrations:** Twilio Media Streams, Telnyx Media Streams, Vonage Voice WebSockets, and direct SIP/RTP trunking.
* **Barge-in / Turn Detection:** Sub-50ms acoustic interruption handling with immediate audio buffer clearing.
* **Multi-Tenancy:** Inbound DNIS dialed-number routing, SIP headers, and ephemeral JWT tokens for browser widgets.
* **Hot-Swapping on the Fly:** Switch speech models, languages (English $\leftrightarrow$ Hindi), and voices mid-call without dropping the line.
* **Native Pure Elixir Brain:** Built-in streaming LLM inference with Groq, Cerebras, OpenAI, Anthropic, DeepSeek, and Ollama.
