# Native Pure Elixir LLM Agent & Streaming Engine

OpenRing Voice Gateway includes a **100% pure Elixir, in-process Conversational Agent Engine**. You do not need to run external Python, NestJS, or microservice backends to have an autonomous, low-latency Voice AI system.

---

## 1. Architecture Overview

```
                      +---------------------------------------+
                      |         Twilio / Telnyx / SIP         |
                      +-------------------+-------------------+
                                          | Inbound Audio (G.711)
                                          v
                              +-----------------------+
                              |      Session.ex       |
                              +---+---------------+---+
                                  |               ^
             Final Transcript (ASR)               | Synthesized Audio Chunks (TTS)
                                  v               |
            +-------------------------------------------+
            |          VoiceGateway.LLM.Agent           |
            |                                           |
            |  +-------------------------------------+  |
            |  |  Task (Finch HTTP/2 SSE Stream)     |  |
            |  |  - Groq (~150ms TTFT)               |  |
            |  |  - Cerebras / OpenAI / Anthropic    |  |
            |  +------------------+------------------+  |
            |                     | Raw Token Stream    |
            |                     v                     |
            |  +-------------------------------------+  |
            |  |      SentenceChunker.ex             |  |
            |  |      - Clause Delimiters (, ; :)    |  |
            |  |      - Sentence Delimiters (. ? !)  |  |
            |  +------------------+------------------+  |
            |                     | Spoken Phrases      |
            |                     v                     |
            |  +-------------------------------------+  |
            |  |       TTSStreamer.stream_text       |  |
            |  +-------------------------------------+  |
            +-------------------------------------------+
```

---

## 2. Low-Latency Optimization Techniques

### A. Sentence & Clause Boundary Chunking
Standard LLMs stream token-by-token (e.g. `"Sure"`, `" I"`, `" can"`, `" help"`).
- **The Problem:** Passing individual words to TTS yields choppy, robotic synthesis with unnatural pitch resets. Waiting for the complete response creates 1.5–3 seconds of dead air.
- **The Solution (`VoiceGateway.LLM.SentenceChunker`):** Tokens are buffered in memory and split at natural phonetic boundaries:
  - First chunk splits early ($\ge 15$ characters at `,`, `.`, `?`, `!`, `\n`) to deliver spoken audio within **250–350ms** of the user finishing speaking.
  - Subsequent chunks accumulate up to 30 characters for maximum voice naturalness.

### B. Instant Conversational Fillers (< 450ms)
If the upstream LLM takes longer than 450ms to deliver its first token (or during complex multi-tool API calls), `Agent.ex` automatically dispatches a dynamic conversational filler:
- *"Sure, let me check that for you."*
- *"One moment please, looking that up."*
- *"Got it, give me just a second."*

This prevents caller abandonment and satisfies telephony keep-alive requirements.

### C. True Mid-Turn Barge-in (< 50ms)
When the caller interrupts while the assistant is speaking:
1. `Session` receives `{:stt_speech_started, call_id}`.
2. `Session` immediately calls `VoiceGateway.LLM.Agent.abort(agent_pid)`.
3. The in-flight `Task` running `Finch.stream` is terminated with `Task.shutdown(task, :brutal_kill)`.
4. `SentenceChunker` buffer is cleared.
5. In-flight TTS synthesis is halted and telephony jitter queues are flushed.

---

## 3. Supported LLM Providers

| Provider | Model Example | Default Base URL | Latency (TTFT) |
| :--- | :--- | :--- | :--- |
| **Groq** *(Recommended)* | `llama-3.3-70b-versatile` | `https://api.groq.com/openai/v1` | ~150ms |
| **Cerebras** | `llama3.1-8b` | `https://api.cerebras.ai/v1` | ~180ms |
| **OpenAI** | `gpt-4o-mini`, `gpt-4o` | `https://api.openai.com/v1` | ~450ms |
| **Anthropic** | `claude-3-5-haiku-20241022` | `https://api.anthropic.com/v1` | ~380ms |
| **DeepSeek** | `deepseek-chat` | `https://api.deepseek.com` | ~500ms |
| **Ollama (Self-Hosted)** | `llama3.1:8b` | `http://localhost:11434/v1` | Hardware-dependent |

---

## 4. Configuration

Set the environment variables in your `.env` or container:

```bash
# Set mode to pure native Elixir
BRAIN_MODE=native

# Provider selection
DEFAULT_LLM_PROVIDER=groq
DEFAULT_LLM_MODEL=llama-3.3-70b-versatile
GROQ_API_KEY=gsk_your_key_here

# System Prompt & Persona
DEFAULT_SYSTEM_PROMPT="You are a professional customer support assistant for Acme Corp. Keep replies concise and conversational (1-2 sentences)."
DEFAULT_GREETING="Hello! Thanks for calling Acme Corp. How can I help you today?"
```

---

## 5. Tool Calling & Telephony Actions

`VoiceGateway.LLM.Tools` provides out-of-the-box telephone actions:

### Call Transfer
When the LLM decides to transfer a call:
```json
{
  "name": "transfer_call",
  "arguments": {
    "destination": "+14155550199",
    "reason": "Caller requested billing department"
  }
}
```
The session receives `{:brain_action, :transfer, %{"target" => "+14155550199"}}` and forwards the transfer command to the telephony carrier (Twilio `<Dial>`, Telnyx Transfer, or SIP REFER).

### Call Hangup
When the conversation reaches a natural close:
```json
{
  "name": "end_call",
  "arguments": {
    "reason": "User completed task"
  }
}
```
The session speaks any final farewell words and terminates the telephony leg.

### Custom Tenant Webhooks & Functions
Tenants can pass custom tool schemas in `opts[:tools]` or define custom handlers executed via concurrent `Task.async_stream`.

---

## 6. Dynamic Reconfiguration (Mid-Call Hot Swap)

You can change an active call's LLM model, system prompt, or provider on the fly via HTTP REST:

```bash
curl -X POST http://localhost:4000/calls/call_abc123/reconfigure \
  -H "Content-Type: application/json" \
  -d '{
    "llm_provider": "openai",
    "llm_model": "gpt-4o",
    "system_prompt": "You are now an escalated tier-2 technical engineer."
  }'
```

`Session.reconfigure/2` updates the in-memory GenServer state without dropping the caller or reconnecting the audio socket.
