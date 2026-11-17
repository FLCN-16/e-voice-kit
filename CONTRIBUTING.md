# Contributing to E-Voice-Kit

First off, thank you for considering contributing to E-Voice-Kit! 🎉

E-Voice-Kit is an open-source, ultra-low-latency real-time voice edge built in Elixir on the BEAM. Our mission is to provide the fastest, most reliable, and easiest-to-self-host voice AI platform in the world.

---

## 🛠️ Development Setup

### Prerequisites
* **Elixir 1.15+** and **Erlang/OTP 26+**
* Git

### Local Setup
```bash
# 1. Clone the repository
git clone https://github.com/FLCN-16/e-voice-kit.git
cd e-voice-kit

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

E-Voice-Kit features a modular, pluggable architecture. Anyone can contribute a new Speech-to-Text (STT), Text-to-Speech (TTS), or Telephony Carrier provider in under 100 lines of Elixir using our base macros and canonical event normalizer.

### Adding an STT Provider
1. Create a module under `lib/e_voice_kit/clients/my_provider_stt.ex`.
2. Adopt `use EVoiceKit.Providers.STT` or `@behaviour EVoiceKit.Providers.STT`.
3. Implement `init_stream/3`, `handle_carrier_audio/2`, and `handle_stream_message/2`:

```elixir
defmodule EVoiceKit.Clients.MyProviderSTT do
  use EVoiceKit.Providers.STT, audio_format: :pcm_16

  @impl EVoiceKit.Providers.STT
  def init_stream(session_pid, call_id, opts) do
    # Open WebSocket to speech provider
    {:ok, %{session_pid: session_pid, call_id: call_id}}
  end

  @impl EVoiceKit.Providers.STT
  def handle_stream_message({:text, json_str}, state) do
    case Jason.decode(json_str) do
      {:ok, %{"transcript" => text, "is_final" => true}} ->
        {:transcript, text, state}

      _ ->
        {:noreply, state}
    end
  end
end
```

4. Register your provider in `config/config.exs` or dynamically via `config :e_voice_kit, :stt_providers, %{my_provider: EVoiceKit.Clients.MyProviderSTT}`.

### Adding a TTS Provider
1. Create a module under `lib/e_voice_kit/clients/my_provider_tts.ex`.
2. Adopt `use EVoiceKit.Providers.TTS, audio_format: :mulaw`.
3. Implement `init_stream/3`, `handle_synthesize_text/3`, and `handle_stream_message/2`.
4. Ensure barge-in cancels in-flight synthesis in $< 50\text{ ms}$.

### Adding a Carrier Transport
1. Create a module under `lib/e_voice_kit/transports/my_carrier_websocket.ex`.
2. Adopt `use EVoiceKit.Transports.WebSocketCarrier`.
3. Implement `parse_incoming_event/2` and `encode_outgoing_audio/3`.

---

## 📐 Code Style & Guidelines

* **Formatting:** Run `mix format` before committing.
* **OTP Idioms:**
  * Keep GenServer callbacks light and non-blocking.
  * Use supervised tasks (`EVoiceKit.TaskSupervisor`) for async operations.
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
* Open a [GitHub Discussion](https://github.com/FLCN-16/e-voice-kit/discussions)
* Open an [Issue](https://github.com/FLCN-16/e-voice-kit/issues) for bug reports and feature requests.
