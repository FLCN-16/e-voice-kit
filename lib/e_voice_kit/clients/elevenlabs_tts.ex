defmodule EVoiceKit.Clients.ElevenLabsTTS do
  @moduledoc """
  Streaming WebSocket client for ElevenLabs Text-to-Speech and Dialogue models.

  Connects to:
  `wss://api.elevenlabs.io/v1/text-to-speech/{voice_id}/stream-input?model_id={model_id}&output_format=ulaw_8000`

  Features:
  - Streaming incremental text tokens into ElevenLabs.
  - Native 8kHz μ-law (`ulaw_8000`) output directly to caller transport (zero transcode overhead).
  - Immediate generation flush and cancellation on caller barge-in.
  """

  @behaviour EVoiceKit.Providers.TTS
  use WebSockex
  require Logger

  @default_host "api.elevenlabs.io"
  @default_voice_id "21m00Tcm4TlvDq8ikWAM" # Rachel
  @default_model_id "eleven_turbo_v2_5"

  defstruct session_pid: nil,
            call_id: nil,
            voice_id: nil,
            model_id: nil,
            api_key: nil,
            initialized: false

  @doc """
  Starts an ElevenLabs streaming TTS WebSocket client for an active call.
  """
  def start_link(session_pid, call_id, opts \\ []) do
    api_key = opts[:api_key] || Application.get_env(:e_voice_kit, :elevenlabs_api_key)
    voice_id = opts[:voice_id] || Application.get_env(:e_voice_kit, :elevenlabs_voice_id, @default_voice_id)
    model_id = opts[:model_id] || Application.get_env(:e_voice_kit, :elevenlabs_model_id, @default_model_id)

    if is_nil(api_key) or api_key == "" do
      Logger.warning("[ElevenLabs:#{call_id}] ELEVENLABS_API_KEY is not configured")
    end

    params =
      URI.encode_query(%{
        "model_id" => model_id,
        "output_format" => "ulaw_8000", # Request native telephony 8kHz μ-law
        "optimize_streaming_latency" => "4"
      })

    url = "wss://#{@default_host}/v1/text-to-speech/#{voice_id}/stream-input?#{params}"

    headers = [
      {"xi-api-key", api_key || ""}
    ]

    state = %__MODULE__{
      session_pid: session_pid,
      call_id: call_id,
      voice_id: voice_id,
      model_id: model_id,
      api_key: api_key,
      initialized: false
    }

    WebSockex.start_link(url, __MODULE__, state, extra_headers: headers)
  end

  @doc """
  Streams a text token or phrase to ElevenLabs.
  """
  def stream_text(pid, text, continue? \\ true) when is_binary(text) do
    WebSockex.cast(pid, {:stream_text, text, continue?})
  end

  @doc """
  Sends an instant abort signal to stop active ElevenLabs generation on barge-in.
  """
  def abort(pid) do
    WebSockex.cast(pid, :abort_generation)
  end

  # WebSockex Callbacks

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("[ElevenLabs:#{state.call_id}] Connected to ElevenLabs WebSocket stream (Voice: #{state.voice_id})")

    # Send initial configuration frame
    init_payload = %{
      "text" => " ",
      "voice_settings" => %{
        "stability" => 0.5,
        "similarity_boost" => 0.8
      },
      "xi_api_key" => state.api_key
    }

    msg = {:text, Jason.encode!(init_payload)}
    {:reply, msg, %{state | initialized: true}}
  end

  @impl true
  def handle_cast({:stream_text, text, continue?}, state) do
    payload =
      if continue? do
        %{
          "text" => text,
          "try_trigger_generation" => true
        }
      else
        # Final text chunk for turn: flush generation
        %{
          "text" => text,
          "flush" => true
        }
      end

    case Jason.encode(payload) do
      {:ok, json} ->
        {:reply, {:text, json}, state}

      {:error, err} ->
        Logger.error("[ElevenLabs:#{state.call_id}] JSON encode error: #{inspect(err)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_cast(:abort_generation, state) do
    Logger.debug("[ElevenLabs:#{state.call_id}] Aborting in-flight ElevenLabs synthesis")
    # Sending empty string with flush clears upstream context
    reset_payload = %{"text" => ""}
    {:reply, {:text, Jason.encode!(reset_payload)}, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"audio" => base64_audio}} when is_binary(base64_audio) and base64_audio != "" ->
        case Base.decode64(base64_audio) do
          {:ok, mulaw_bytes} ->
            send(state.session_pid, {:tts_audio_chunk, mulaw_bytes})
            {:ok, state}

          :error ->
            {:ok, state}
        end

      {:ok, %{"isFinal" => true}} ->
        Logger.debug("[ElevenLabs:#{state.call_id}] Generation completed")
        send(state.session_pid, {:tts_turn_completed, state.call_id})
        {:ok, state}

      {:ok, %{"normalizedAlignment" => align}} ->
        Logger.debug("[ElevenLabs:#{state.call_id}] Word alignment: #{inspect(align)}")
        {:ok, state}

      {:ok, %{"error" => err}} ->
        Logger.error("[ElevenLabs:#{state.call_id}] ElevenLabs error: #{inspect(err)}")
        {:ok, state}

      {:ok, _other} ->
        {:ok, state}

      {:error, err} ->
        Logger.warning("[ElevenLabs:#{state.call_id}] Failed to decode response: #{inspect(err)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_frame({:binary, _}, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.info("[ElevenLabs:#{state.call_id}] ElevenLabs disconnected: #{inspect(reason)}")
    {:ok, state}
  end
end
