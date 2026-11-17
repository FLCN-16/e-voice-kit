defmodule EVoiceKit.Clients.DeepgramSTT do
  @moduledoc """
  Streaming WebSocket client for Deepgram Nova-2 / Nova-3 Speech-to-Text.

  Streams raw 8kHz G.711 μ-law telephony audio directly to Deepgram's cloud endpoint.
  Emits:
  - `{:stt_speech_started, call_id}` -> Instant barge-in / speech detection.
  - `{:stt_transcript, call_id, text, is_final}` -> Transcribed user speech.
  """

  @behaviour EVoiceKit.Providers.STT
  use WebSockex
  require Logger

  @deepgram_host "api.deepgram.com"

  defstruct session_pid: nil,
            call_id: nil

  @doc """
  Starts a new Deepgram streaming STT connection for a call.
  """
  def start_link(session_pid, call_id, opts \\ []) do
    api_key = opts[:api_key] || Application.get_env(:e_voice_kit, :deepgram_api_key)

    if is_nil(api_key) or api_key == "" do
      Logger.warning("[STT:#{call_id}] DEEPGRAM_API_KEY is not configured; running in mock/offline mode")
    end

    params =
      URI.encode_query(%{
        "encoding" => "mulaw",
        "sample_rate" => "8000",
        "channels" => "1",
        "endpointing" => "300",
        "interim_results" => "true",
        "smart_format" => "true"
      })

    url = "wss://#{@deepgram_host}/v1/listen?#{params}"

    headers = [
      {"Authorization", "Token #{api_key}"},
      {"Content-Type", "audio/mulaw"}
    ]

    state = %__MODULE__{
      session_pid: session_pid,
      call_id: call_id
    }

    WebSockex.start_link(url, __MODULE__, state, extra_headers: headers)
  end

  @doc """
  Streams a chunk of raw μ-law audio to Deepgram.
  """
  def send_audio(pid, chunk) when is_binary(chunk) do
    WebSockex.send_frame(pid, {:binary, chunk})
  end

  @doc """
  Closes the STT stream cleanly.
  """
  def close(pid) do
    # Tell Deepgram stream is closing
    WebSockex.send_frame(pid, {:text, Jason.encode!(%{"type" => "CloseStream"})})
  end

  # WebSockex Callbacks

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("[STT:#{state.call_id}] Connected to Deepgram Live Stream")
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"type" => "SpeechStarted"}} ->
        Logger.debug("[STT:#{state.call_id}] SpeechStarted detected (Barge-in candidate)")
        send(state.session_pid, {:stt_speech_started, state.call_id})
        {:ok, state}

      {:ok, %{"type" => "UtteranceEnd"}} ->
        Logger.debug("[STT:#{state.call_id}] UtteranceEnd detected (endpointing silence)")
        send(state.session_pid, {:stt_speech_ended, state.call_id})
        {:ok, state}

      {:ok, %{"type" => "Results"} = results} ->
        handle_results(results, state)
        {:ok, state}

      {:ok, %{"type" => "Metadata"} = meta} ->
        Logger.debug("[STT:#{state.call_id}] Deepgram Metadata: #{inspect(meta)}")
        {:ok, state}

      {:ok, %{"type" => "Error"} = err} ->
        Logger.error("[STT:#{state.call_id}] Deepgram Error: #{inspect(err)}")
        {:ok, state}

      {:ok, _other} ->
        {:ok, state}

      {:error, err} ->
        Logger.warning("[STT:#{state.call_id}] Failed to decode STT JSON: #{inspect(err)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_frame({:binary, _data}, state) do
    {:ok, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.info("[STT:#{state.call_id}] Deepgram disconnected: #{inspect(reason)}")
    {:ok, state}
  end

  # Private Helpers

  defp handle_results(%{"channel" => %{"alternatives" => [alt | _]}} = results, state) do
    transcript = Map.get(alt, "transcript", "")
    is_final = Map.get(results, "is_final", false)
    speech_final = Map.get(results, "speech_final", false)

    if transcript != "" do
      send(state.session_pid, {:stt_transcript, state.call_id, transcript, is_final, speech_final})
    end
  end

  defp handle_results(_results, _state), do: :ok
end
