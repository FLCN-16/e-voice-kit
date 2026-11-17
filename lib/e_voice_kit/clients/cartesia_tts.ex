defmodule EVoiceKit.Clients.CartesiaTTS do
  @moduledoc """
  Streaming WebSocket client for Cartesia Sonic Text-to-Speech.
  Implements `EVoiceKit.Providers.TTS`.
  """

  @behaviour EVoiceKit.Providers.TTS
  use WebSockex
  require Logger
  alias EVoiceKit.Codec.G711

  @default_cartesia_url "wss://api.cartesia.ai/tts/websocket"

  defstruct session_pid: nil,
            call_id: nil,
            context_id: nil,
            voice_id: nil

  @impl EVoiceKit.Providers.TTS
  def start_link(session_pid, call_id, opts \\ []) do
    api_key = opts[:api_key] || Application.get_env(:e_voice_kit, :cartesia_api_key)
    voice_id = opts[:voice_id] || "a0e99841-438c-4a64-b679-ae501e7d6091"

    url = "#{@default_cartesia_url}?api_key=#{api_key}&cartesia_version=2024-06-10"

    state = %__MODULE__{
      session_pid: session_pid,
      call_id: call_id,
      voice_id: voice_id,
      context_id: "ctx_#{call_id}_#{System.unique_integer([:positive])}"
    }

    WebSockex.start_link(url, __MODULE__, state)
  end

  @impl EVoiceKit.Providers.TTS
  def stream_text(pid, text, continue? \\ true) when is_binary(text) do
    WebSockex.cast(pid, {:stream_text, text, continue?})
  end

  @impl EVoiceKit.Providers.TTS
  def abort(pid) do
    WebSockex.cast(pid, :abort_generation)
  end

  # WebSockex Callbacks

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("[Cartesia:#{state.call_id}] Connected to Cartesia TTS stream")
    {:ok, state}
  end

  @impl true
  def handle_cast({:stream_text, text, continue?}, state) do
    payload = %{
      "context_id" => state.context_id,
      "model_id" => "sonic-english",
      "transcript" => text,
      "duration" => nil,
      "voice" => %{
        "mode" => "id",
        "id" => state.voice_id
      },
      "output_format" => %{
        "container" => "raw",
        "encoding" => "pcm_mulaw", # Request native 8kHz μ-law directly
        "sample_rate" => 8000
      },
      "continue" => continue?
    }

    case Jason.encode(payload) do
      {:ok, json} ->
        {:reply, {:text, json}, state}

      {:error, err} ->
        Logger.error("[Cartesia:#{state.call_id}] Error encoding payload: #{inspect(err)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_cast(:abort_generation, state) do
    new_context = "ctx_#{state.call_id}_#{System.unique_integer([:positive])}"
    cancel_payload = %{"context_id" => state.context_id, "cancel" => true}

    msg = {:text, Jason.encode!(cancel_payload)}
    {:reply, msg, %{state | context_id: new_context}}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"data" => base64_audio, "context_id" => ctx}} when ctx == state.context_id ->
        case Base.decode64(base64_audio) do
          {:ok, audio_bytes} ->
            send(state.session_pid, {:tts_audio_chunk, audio_bytes})
            {:ok, state}

          :error ->
            {:ok, state}
        end

      {:ok, %{"done" => true, "context_id" => ctx}} when ctx == state.context_id ->
        send(state.session_pid, {:tts_turn_completed, state.call_id})
        {:ok, state}

      {:ok, %{"error" => err}} ->
        Logger.error("[Cartesia:#{state.call_id}] Cartesia error: #{inspect(err)}")
        {:ok, state}

      {:ok, _stale_or_other} ->
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
    Logger.info("[Cartesia:#{state.call_id}] Cartesia disconnected: #{inspect(reason)}")
    {:ok, state}
  end
end
