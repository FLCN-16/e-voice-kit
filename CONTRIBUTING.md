# Contributing to VoiceGateway

First off, thank you for considering contributing to VoiceGateway! 🎉

VoiceGateway is an open-source, ultra-low-latency real-time voice edge built in Elixir on the BEAM. Our mission is to provide the fastest, most reliable, and easiest-to-self-host voice AI platform in the world.

---

## 🛠️ Development Setup

### Prerequisites
* **Elixir 1.15+** and **Erlang/OTP 26+**
* Git

### Local Setup
```bash
# 1. Clone the repository
git clone https://github.com/your-org/voice-gateway.git
cd voice-gateway/elixir

# 2. Install dependencies
mix deps.get

# 3. Copy sample environment file
cp .env.example .env

# 4. Run the test suite
mix test

# 5. Start interactive console with server
iex -S mix
```

The server will start on `http://localhost:4000`.

---

## 🔌 Authoring a New Pluggable Provider

VoiceGateway features a modular, pluggable architecture. Anyone can contribute a new Speech-to-Text (STT) or Text-to-Speech (TTS) provider in under 100 lines of Elixir.

### Adding an STT Provider
1. Create a module under `lib/voice_gateway/clients/my_provider_stt.ex`.
2. Adopt the `@behaviour VoiceGateway.Providers.STT`.
3. Implement `start_link/3`, `send_audio/2`, and `close/1`:

```elixir
defmodule VoiceGateway.Clients.MyProviderSTT do
  @behaviour VoiceGateway.Providers.STT
  use WebSockex

  @impl VoiceGateway.Providers.STT
  def start_link(session_pid, call_id, opts) do
    # Open WebSocket to speech provider
  end

  @impl VoiceGateway.Providers.STT
  def send_audio(pid, mulaw_chunk) do
    # Stream audio frame
  end

  @impl VoiceGateway.Providers.STT
  def close(pid) do
    # Disconnect cleanly
  end
end
```

4. Register your provider in `config/config.exs` or `lib/voice_gateway/clients/stt_streamer.ex`.

### Adding a TTS Provider
1. Create a module under `lib/voice_gateway/clients/my_provider_tts.ex`.
2. Adopt the `@behaviour VoiceGateway.Providers.TTS`.
3. Implement `start_link/3`, `stream_text/3`, and `abort/1`.
4. Ensure barge-in (`abort/1`) cancels in-flight synthesis in $< 50\text{ ms}$.

---

## 📐 Code Style & Guidelines

* **Formatting:** Run `mix format` before committing.
* **OTP Idioms:**
  * Keep GenServer callbacks light and non-blocking.
  * Use supervised tasks (`VoiceGateway.TaskSupervisor`) for async operations.
  * Use native binary pattern matching for binary/audio transformations.
* **Documentation:** All public functions should have `@doc` and `@spec` type annotations.

---

## 🚀 Submitting Pull Requests

1. **Fork the repo** and create your branch from `main`:
   ```bash
   git checkout -b feature/my-cool-provider
   ```
2. **Write tests** under `test/` verifying your functionality.
3. Ensure all tests pass:
   ```bash
   mix test
   ```
4. **Commit with clear messages**:
   ```bash
   git commit -m "feat(providers): add Whisper live streaming STT"
   ```
5. **Open a Pull Request** with a description of what was added and how you tested it.

---

## 💬 Community & Help
Have questions or want to discuss architecture?
* Open a [GitHub Discussion](https://github.com/your-org/voice-gateway/discussions)
* Open an [Issue](https://github.com/your-org/voice-gateway/issues) for bug reports and feature requests.
