defmodule EVoiceKit.Clients.FishAudioTTS do
  @moduledoc """
  Streaming client for Fish Audio Text-to-Speech (supporting `s2.1-pro` model).

  Utilizes Finch HTTP/2 streaming chunks with low-latency transfer encoding.
  Receives 8kHz linear PCM directly from Fish Audio, encodes to G.711 μ-law
  using `EVoiceKit.Codec.G711`, and dispatches to the live caller.
  Supports instant cancellation on barge-in.
  """

  @behaviour EVoiceKit.Providers.TTS
  use GenServer
  require Logger

  alias EVoiceKit.Codec.G711

  @fish_endpoint "https://api.fish.audio/v1/tts"
  @default_model "s2.1-pro"

  defstruct session_pid: nil,
            call_id: nil,
            api_key: nil,
            model: nil,
            voice_id: nil,
            current_task: nil

  @doc """
  Starts a Fish Audio TTS client for an active call.
  """
  def start_link(session_pid, call_id, opts \\ []) do
    GenServer.start_link(__MODULE__, {session_pid, call_id, opts})
  end

  @doc """
  Streams a text token or phrase to Fish Audio for synthesis.
  """
  def stream_text(pid, text, continue? \\ true) when is_binary(text) do
    GenServer.cast(pid, {:stream_text, text, continue?})
  end

  @doc """
  Aborts active Fish Audio synthesis on caller barge-in.
  """
  def abort(pid) do
    GenServer.cast(pid, :abort_generation)
  end

  # GenServer Callbacks

  @impl true
  def init({session_pid, call_id, opts}) do
    api_key = opts[:api_key] || Application.get_env(:e_voice_kit, :fishaudio_api_key)
    model = opts[:model] || Application.get_env(:e_voice_kit, :fishaudio_model, @default_model)
    voice_id = opts[:voice_id] || Application.get_env(:e_voice_kit, :fishaudio_voice_id)

    if is_nil(api_key) or api_key == "" do
      Logger.warning("[FishAudio:#{call_id}] FISHAUDIO_API_KEY is not configured")
    end

    state = %__MODULE__{
      session_pid: session_pid,
      call_id: call_id,
      api_key: api_key,
      model: model,
      voice_id: voice_id,
      current_task: nil
    }

    Logger.info("[FishAudio:#{call_id}] Initialized Fish Audio client (Model: #{model})")
    {:ok, state}
  end

  @impl true
  def handle_cast({:stream_text, text, _continue?}, state) do
    # Cancel previous in-flight task if still generating
    state = cancel_current_task(state)

    session_pid = state.session_pid
    call_id = state.call_id
    api_key = state.api_key
    model = state.model
    voice_id = state.voice_id

    # Spawn async streaming task using Finch HTTP/2
    task =
      Task.async(fn ->
        body =
          %{
            "text" => text,
            "format" => "pcm",
            "sample_rate" => 8000, # 8kHz telephony PCM
            "latency" => "balanced"
          }
          |> maybe_put_reference_id(voice_id)
          |> Jason.encode!()

        headers = [
          {"authorization", "Bearer #{api_key}"},
          {"content-type", "application/json"},
          {"model", model}
        ]

        req = Finch.build(:post, @fish_endpoint, headers, body)

        Finch.stream(req, EVoiceKit.Finch, nil, fn
          {:status, status}, acc when status in 200..299 ->
            acc

          {:data, raw_pcm_chunk}, acc ->
            # Convert incoming 16-bit linear PCM into G.711 μ-law
            mulaw = G711.encode_mulaw(raw_pcm_chunk)
            send(session_pid, {:tts_audio_chunk, mulaw})
            acc

          {:status, err_status}, acc ->
            Logger.error("[FishAudio:#{call_id}] Stream failed with HTTP status #{err_status}")
            acc

          _other, acc ->
            acc
        end)

        send(session_pid, {:tts_turn_completed, call_id})
      end)

    {:noreply, %{state | current_task: task}}
  end

  @impl true
  def handle_cast(:abort_generation, state) do
    Logger.debug("[FishAudio:#{state.call_id}] Aborting in-flight Fish Audio generation on barge-in")
    state = cancel_current_task(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, _result}, %{current_task: %Task{ref: ref}} = state) do
    # Task completed normally
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | current_task: nil}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{current_task: %Task{ref: ref}} = state) do
    {:noreply, %{state | current_task: nil}}
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  # Helpers

  defp cancel_current_task(%{current_task: %Task{} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    %{state | current_task: nil}
  end

  defp cancel_current_task(state), do: state

  defp maybe_put_reference_id(map, nil), do: map
  defp maybe_put_reference_id(map, id), do: Map.put(map, "reference_id", id)
end
