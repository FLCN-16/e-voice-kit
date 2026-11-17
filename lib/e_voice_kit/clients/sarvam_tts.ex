defmodule EVoiceKit.Clients.SarvamTTS do
  @moduledoc """
  Streaming WebSocket client for Sarvam AI Bulbul Text-to-Speech.

  Generates high-naturalness speech for Indian languages (Hindi, Tamil, Telugu,
  Kannada, Bengali, Marathi, Gujarati, etc.).
  Connects to `wss://api.sarvam.ai/text-to-speech/ws`.
  Audio received is transcoded to G.711 μ-law for telephony playback.
  """

  @behaviour EVoiceKit.Providers.TTS
  use WebSockex
  require Logger
  alias EVoiceKit.Codec.G711

  @default_host "api.sarvam.ai"
  @default_speaker "meera"
  @default_language "hi-IN"

  defstruct session_pid: nil,
            call_id: nil,
            language_code: @default_language,
            speaker: @default_speaker,
            model: "bulbul:v2",
            api_key: nil

  @doc """
  Starts a Sarvam AI TTS streaming client for an active call.
  """
  @impl EVoiceKit.Providers.TTS
  def start_link(session_pid, call_id, opts \\ []) do
    api_key = opts[:api_key] || Application.get_env(:e_voice_kit, :sarvam_api_key)
    language_code = opts[:language_code] || Application.get_env(:e_voice_kit, :sarvam_tts_language, @default_language)
    speaker = opts[:speaker] || Application.get_env(:e_voice_kit, :sarvam_tts_speaker, @default_speaker)
    model = opts[:model] || "bulbul:v2"

    if is_nil(api_key) or api_key == "" do
      Logger.warning("[SarvamTTS:#{call_id}] SARVAM_API_KEY is not configured")
    end

    url = "wss://#{@default_host}/text-to-speech/ws"

    headers = [
      {"api-subscription-key", api_key || ""}
    ]

    state = %__MODULE__{
      session_pid: session_pid,
      call_id: call_id,
      language_code: language_code,
      speaker: speaker,
      model: model,
      api_key: api_key
    }

    WebSockex.start_link(url, __MODULE__, state, extra_headers: headers)
  end

  @doc """
  Streams a text token or phrase to Sarvam Bulbul.
  """
  @impl EVoiceKit.Providers.TTS
  def stream_text(pid, text, continue? \\ true) when is_binary(text) do
    WebSockex.cast(pid, {:stream_text, text, continue?})
  end

  @doc """
  Aborts active Sarvam generation on barge-in.
  """
  @impl EVoiceKit.Providers.TTS
  def abort(pid) do
    WebSockex.cast(pid, :abort_generation)
  end

  # WebSockex Callbacks

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("[SarvamTTS:#{state.call_id}] Connected to Sarvam TTS stream (Lang: #{state.language_code}, Speaker: #{state.speaker})")

    # Send initial configuration frame
    init_payload = %{
      "language_code" => state.language_code,
      "speaker" => state.speaker,
      "model" => state.model,
      "sample_rate" => 8000
    }

    msg = {:text, Jason.encode!(init_payload)}
    {:reply, msg, state}
  end

  @impl true
  def handle_cast({:stream_text, text, continue?}, state) do
    payload = %{
      "text" => text,
      "flush" => not continue?
    }

    case Jason.encode(payload) do
      {:ok, json} ->
        {:reply, {:text, json}, state}

      {:error, err} ->
        Logger.error("[SarvamTTS:#{state.call_id}] JSON encode error: #{inspect(err)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_cast(:abort_generation, state) do
    Logger.debug("[SarvamTTS:#{state.call_id}] Aborting in-flight Sarvam TTS generation")
    reset_payload = %{"text" => "", "flush" => true}
    {:reply, {:text, Jason.encode!(reset_payload)}, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"audio" => base64_audio}} when is_binary(base64_audio) and base64_audio != "" ->
        case Base.decode64(base64_audio) do
          {:ok, raw_pcm} ->
            mulaw = G711.encode_mulaw(raw_pcm)
            send(state.session_pid, {:tts_audio_chunk, mulaw})
            {:ok, state}

          :error ->
            {:ok, state}
        end

      {:ok, %{"is_final" => true}} ->
        send(state.session_pid, {:tts_turn_completed, state.call_id})
        {:ok, state}

      {:ok, _} ->
        {:ok, state}

      {:error, _} ->
        {:ok, state}
    end
  end

  @impl true
  def handle_frame({:binary, raw_pcm}, state) do
    mulaw = G711.encode_mulaw(raw_pcm)
    send(state.session_pid, {:tts_audio_chunk, mulaw})
    {:ok, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.info("[SarvamTTS:#{state.call_id}] Sarvam TTS disconnected: #{inspect(reason)}")
    {:ok, state}
  end
end
