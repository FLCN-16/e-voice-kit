defmodule EVoiceKit.Clients.AssemblyAISTT do
  @moduledoc """
  Streaming WebSocket client for AssemblyAI Universal-2 Speech-to-Text.

  Connects to `wss://api.assemblyai.com/v2/realtime/ws?sample_rate=8000`.
  Converts telephony G.711 μ-law audio to 16-bit linear PCM on the fly and streams
  binary frames to AssemblyAI.
  Emits:
  - `{:stt_speech_started, call_id}` on PartialTranscript.
  - `{:stt_transcript, call_id, text, is_final, speech_final}` on FinalTranscript.
  """

  @behaviour EVoiceKit.Providers.STT
  use WebSockex
  require Logger
  alias EVoiceKit.Codec.G711

  @default_host "api.assemblyai.com"

  defstruct session_pid: nil,
            call_id: nil

  @doc """
  Starts an AssemblyAI streaming STT WebSocket client for an active call.
  """
  @impl EVoiceKit.Providers.STT
  def start_link(session_pid, call_id, opts \\ []) do
    api_key = opts[:api_key] || Application.get_env(:e_voice_kit, :assemblyai_api_key)

    if is_nil(api_key) or api_key == "" do
      Logger.warning("[AssemblyAI:#{call_id}] ASSEMBLYAI_API_KEY is not configured")
    end

    url = "wss://#{@default_host}/v2/realtime/ws?sample_rate=8000"

    headers = [
      {"Authorization", api_key || ""}
    ]

    state = %__MODULE__{
      session_pid: session_pid,
      call_id: call_id
    }

    WebSockex.start_link(url, __MODULE__, state, extra_headers: headers)
  end

  @doc """
  Streams a chunk of telephony μ-law audio to AssemblyAI (automatically transcoded to linear PCM).
  """
  @impl EVoiceKit.Providers.STT
  def send_audio(pid, mulaw_chunk) when is_binary(mulaw_chunk) do
    # AssemblyAI expects 16-bit signed little-endian linear PCM
    pcm_audio = G711.decode_mulaw(mulaw_chunk)
    WebSockex.send_frame(pid, {:binary, pcm_audio})
  end

  @doc """
  Signals the end of speech stream to AssemblyAI.
  """
  @impl EVoiceKit.Providers.STT
  def close(pid) do
    terminate_payload = %{"terminate_session" => true}
    WebSockex.send_frame(pid, {:text, Jason.encode!(terminate_payload)})
  end

  # WebSockex Callbacks

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("[AssemblyAI:#{state.call_id}] Connected to AssemblyAI Realtime Stream")
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"message_type" => "SessionBegins", "session_id" => sid}} ->
        Logger.info("[AssemblyAI:#{state.call_id}] Session Began: #{sid}")
        {:ok, state}

      {:ok, %{"message_type" => "PartialTranscript", "text" => text}} ->
        if String.trim(text) != "" do
          # Trigger early barge-in when words start being recognized
          send(state.session_pid, {:stt_speech_started, state.call_id})
        end

        {:ok, state}

      {:ok, %{"message_type" => "FinalTranscript", "text" => text}} ->
        trimmed = String.trim(text)

        if trimmed != "" do
          Logger.info("[AssemblyAI:#{state.call_id}] Final utterance: #{inspect(trimmed)}")
          send(state.session_pid, {:stt_transcript, state.call_id, trimmed, true, true})
        end

        {:ok, state}

      {:ok, %{"message_type" => "SessionTerminated"}} ->
        Logger.info("[AssemblyAI:#{state.call_id}] Session terminated by server")
        {:ok, state}

      {:ok, %{"error" => err}} ->
        Logger.error("[AssemblyAI:#{state.call_id}] AssemblyAI Realtime Error: #{inspect(err)}")
        {:ok, state}

      {:ok, _other} ->
        {:ok, state}

      {:error, err} ->
        Logger.warning("[AssemblyAI:#{state.call_id}] JSON decode error: #{inspect(err)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_frame({:binary, _}, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.info("[AssemblyAI:#{state.call_id}] AssemblyAI disconnected: #{inspect(reason)}")
    {:ok, state}
  end
end
