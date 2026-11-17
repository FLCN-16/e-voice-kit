defmodule EVoiceKit.Clients.SarvamSTT do
  @moduledoc """
  Streaming WebSocket client for Sarvam AI Saaras Speech-to-Text.

  Specialized for 10+ Indian languages (Hindi, Tamil, Telugu, Kannada, Bengali, etc.).
  Connects to `wss://api.sarvam.ai/speech-to-text-realtime/ws`.
  """

  @behaviour EVoiceKit.Providers.STT
  use WebSockex
  require Logger
  alias EVoiceKit.Codec.G711

  @default_host "api.sarvam.ai"

  defstruct session_pid: nil,
            call_id: nil,
            language_code: "hi-IN",
            model: "saaras:v2"

  @doc """
  Starts a Sarvam AI STT streaming client for an active call.
  """
  @impl EVoiceKit.Providers.STT
  def start_link(session_pid, call_id, opts \\ []) do
    api_key = opts[:api_key] || Application.get_env(:e_voice_kit, :sarvam_api_key)
    language_code = opts[:language_code] || Application.get_env(:e_voice_kit, :sarvam_stt_language, "hi-IN")
    model = opts[:model] || "saaras:v2"

    if is_nil(api_key) or api_key == "" do
      Logger.warning("[SarvamSTT:#{call_id}] SARVAM_API_KEY is not configured")
    end

    params =
      URI.encode_query(%{
        "language_code" => language_code,
        "model" => model,
        "sample_rate" => "8000"
      })

    url = "wss://#{@default_host}/speech-to-text-realtime/ws?#{params}"

    headers = [
      {"api-subscription-key", api_key || ""}
    ]

    state = %__MODULE__{
      session_pid: session_pid,
      call_id: call_id,
      language_code: language_code,
      model: model
    }

    WebSockex.start_link(url, __MODULE__, state, extra_headers: headers)
  end

  @doc """
  Streams a chunk of telephony μ-law audio to Sarvam AI (decoded to 16-bit linear PCM).
  """
  @impl EVoiceKit.Providers.STT
  def send_audio(pid, mulaw_chunk) when is_binary(mulaw_chunk) do
    pcm_audio = G711.decode_mulaw(mulaw_chunk)
    WebSockex.send_frame(pid, {:binary, pcm_audio})
  end

  @doc """
  Closes the streaming STT connection.
  """
  @impl EVoiceKit.Providers.STT
  def close(pid) do
    WebSockex.send_frame(pid, {:text, Jason.encode!(%{"type" => "flush"})})
  end

  # WebSockex Callbacks

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("[SarvamSTT:#{state.call_id}] Connected to Sarvam STT stream (Lang: #{state.language_code})")
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"transcript" => text, "is_final" => true}} ->
        trimmed = String.trim(text)

        if trimmed != "" do
          Logger.info("[SarvamSTT:#{state.call_id}] Final transcript: #{inspect(trimmed)}")
          send(state.session_pid, {:stt_transcript, state.call_id, trimmed, true, true})
        end

        {:ok, state}

      {:ok, %{"transcript" => text}} ->
        if String.trim(text) != "" do
          send(state.session_pid, {:stt_speech_started, state.call_id})
        end

        {:ok, state}

      {:ok, _} ->
        {:ok, state}

      {:error, err} ->
        Logger.warning("[SarvamSTT:#{state.call_id}] Failed to decode STT JSON: #{inspect(err)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_frame({:binary, _}, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.info("[SarvamSTT:#{state.call_id}] Sarvam STT disconnected: #{inspect(reason)}")
    {:ok, state}
  end
end
