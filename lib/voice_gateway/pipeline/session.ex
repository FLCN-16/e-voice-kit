defmodule VoiceGateway.Pipeline.Session do
  @moduledoc """
  Core GenServer managing the lifecycle, turn state machine, and audio coordination of one live call.

  Supervised dynamically by `VoiceGateway.Pipeline.SessionSupervisor`.
  Registered in `VoiceGateway.SessionRegistry` via `{:via, Registry, {VoiceGateway.SessionRegistry, call_id}}`.
  """

  use GenServer, restart: :temporary
  require Logger

  alias VoiceGateway.Pipeline.Buffer
  alias VoiceGateway.Clients.{STTStreamer, TTSStreamer, BrainBridge}
  alias VoiceGateway.LLM.Agent, as: LLMAgent

  defstruct call_id: nil,
            transport_pid: nil,
            transport_monitor: nil,
            stt_handle: nil, # {module, pid} or pid
            tts_handle: nil, # {module, pid} or pid
            brain_pid: nil,
            agent_pid: nil,
            buffer: nil,
            status: :listening, # :listening | :speaking | :thinking | :ended
            start_time: nil,
            turns_count: 0,
            config: []

  @type status :: :listening | :speaking | :thinking | :ended

  # Client API

  @doc """
  Starts a supervised call session for an incoming call stream.
  """
  def start_link(opts) do
    call_id = Keyword.fetch!(opts, :call_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(call_id))
  end

  @doc """
  Dynamically reconfigures an active call's STT/TTS providers, models, languages,
  voices, or speakers on the fly without interrupting telephony audio.
  """
  def reconfigure(call_id, new_config) when is_binary(call_id) do
    case VoiceGateway.get_session(call_id) do
      {:ok, pid} -> GenServer.call(pid, {:reconfigure, new_config})
      error -> error
    end
  end

  def reconfigure(pid, new_config) when is_pid(pid) do
    GenServer.call(pid, {:reconfigure, new_config})
  end

  def via_tuple(call_id) do
    {:via, Registry, {VoiceGateway.SessionRegistry, call_id}}
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    # Trap exits so child crashes (e.g. STT disconnect) don't immediately kill the phone call
    Process.flag(:trap_exit, true)

    call_id = Keyword.fetch!(opts, :call_id)
    transport_pid = Keyword.fetch!(opts, :transport_pid)

    # Monitor telephony transport so we clean up immediately if caller drops
    transport_monitor = Process.monitor(transport_pid)

    Logger.info("[Session:#{call_id}] Initializing call session with opts: #{inspect(opts)}")

    # Start child clients (STT, TTS, Native LLM Agent / BrainBridge)
    stt_handle =
      case STTStreamer.start_link(self(), call_id, opts) do
        {:ok, handle} -> handle
        {:error, err} ->
          Logger.error("[Session:#{call_id}] Failed to start initial STT: #{inspect(err)}")
          nil
      end

    tts_handle =
      case TTSStreamer.start_link(self(), call_id, opts) do
        {:ok, handle} -> handle
        {:error, err} ->
          Logger.error("[Session:#{call_id}] Failed to start initial TTS: #{inspect(err)}")
          nil
      end

    brain_mode =
      Keyword.get(opts, :brain_mode) ||
        Application.get_env(:voice_gateway, :brain_mode, :native)

    {brain_pid, agent_pid} =
      case brain_mode do
        :bridge ->
          case BrainBridge.start_link(self(), call_id, opts) do
            {:ok, pid} -> {pid, nil}
            {:error, err} ->
              Logger.error("[Session:#{call_id}] Failed to connect to Brain Bridge: #{inspect(err)}")
              {nil, nil}
          end

        _native ->
          case LLMAgent.start_link(self(), call_id, opts) do
            {:ok, pid} -> {nil, pid}
            {:error, err} ->
              Logger.error("[Session:#{call_id}] Failed to start Native LLM Agent: #{inspect(err)}")
              {nil, nil}
          end
      end

    # Speak initial greeting if configured
    greeting = opts[:greeting] || opts["greeting"]
    if greeting && String.trim(to_string(greeting)) != "" and tts_handle do
      Logger.info("[Session:#{call_id}] Speaking initial greeting: #{inspect(greeting)}")
      TTSStreamer.stream_text(tts_handle, to_string(greeting), false)
    end

    state = %__MODULE__{
      call_id: call_id,
      transport_pid: transport_pid,
      transport_monitor: transport_monitor,
      stt_handle: stt_handle,
      tts_handle: tts_handle,
      brain_pid: brain_pid,
      agent_pid: agent_pid,
      buffer: Buffer.new(160),
      status: if(greeting && greeting != "", do: :speaking, else: :listening),
      start_time: System.monotonic_time(:millisecond),
      turns_count: 0,
      config: opts
    }

    {:ok, state}
  end

  # Inbound Audio from Caller Transport (Twilio / Telnyx)
  @impl true
  def handle_info({:caller_audio, binary_mulaw}, state) do
    if state.stt_handle do
      STTStreamer.send_audio(state.stt_handle, binary_mulaw)
    end

    {:noreply, state}
  end

  # Barge-in / Speech Detection from STT
  @impl true
  def handle_info({:stt_speech_started, _call_id}, state) do
    Logger.debug("[Session:#{state.call_id}] Speech detected! Evaluating barge-in (status: #{state.status})")

    if state.status in [:speaking, :thinking] do
      Logger.info("[Session:#{state.call_id}] Barge-in triggered! Halting TTS, flushing buffers, aborting brain run")

      # 1. Instantly abort in-flight TTS synthesis
      if state.tts_handle, do: TTSStreamer.abort(state.tts_handle)

      # 2. Tell caller transport to clear its internal audio queue
      send(state.transport_pid, :clear_audio)

      # 3. Notify Native Agent or NestJS brain to abort LLM / tool tasks
      if state.agent_pid, do: LLMAgent.abort(state.agent_pid)
      if state.brain_pid, do: BrainBridge.send_interrupt(state.brain_pid)

      # 4. Flush local audio buffer
      flushed_buffer = Buffer.flush(state.buffer)

      {:noreply, %{state | status: :listening, buffer: flushed_buffer}}
    else
      {:noreply, state}
    end
  end

  # Transcribed Utterance from STT
  @impl true
  def handle_info({:stt_transcript, _call_id, transcript, _is_final, speech_final}, state) do
    if speech_final do
      Logger.info("[Session:#{state.call_id}] User turn completed: #{inspect(transcript)}")

      # Forward final utterance to Native LLM Agent or external Brain Bridge
      cond do
        state.agent_pid ->
          LLMAgent.user_turn(state.agent_pid, transcript)

        state.brain_pid ->
          BrainBridge.send_user_turn(state.brain_pid, transcript)

        true ->
          :ok
      end

      {:noreply, %{state | status: :thinking, turns_count: state.turns_count + 1}}
    else
      {:noreply, state}
    end
  end

  # Session Initialization from Brain (multi-tenant assistant config + optional initial greeting)
  @impl true
  def handle_info({:brain_init_session, config}, state) do
    Logger.info("[Session:#{state.call_id}] Applying assistant config from brain: #{inspect(config)}")
    state = apply_reconfiguration(state, config)

    # If greeting provided in config, speak it immediately
    greeting = config["greeting"] || config[:greeting]

    if greeting && String.trim(to_string(greeting)) != "" do
      Logger.info("[Session:#{state.call_id}] Speaking initial assistant greeting: #{inspect(greeting)}")
      TTSStreamer.stream_text(state.tts_handle, greeting, false)
      {:noreply, %{state | status: :speaking}}
    else
      {:noreply, state}
    end
  end

  # Explicit Greeting Message from Brain
  @impl true
  def handle_info({:brain_greeting, greeting_text}, state) do
    Logger.info("[Session:#{state.call_id}] Speaking greeting: #{inspect(greeting_text)}")
    TTSStreamer.stream_text(state.tts_handle, greeting_text, false)
    {:noreply, %{state | status: :speaking}}
  end

  # Immediate Conversational Filler from Brain (e.g. "Let me look into that...")
  @impl true
  def handle_info({:brain_filler, filler_text}, state) do
    Logger.info("[Session:#{state.call_id}] Speaking filler: #{inspect(filler_text)}")
    TTSStreamer.stream_text(state.tts_handle, filler_text, false)
    {:noreply, %{state | status: :speaking}}
  end

  # Streaming Token from Brain
  @impl true
  def handle_info({:brain_token, token}, state) do
    TTSStreamer.stream_text(state.tts_handle, token, true)
    {:noreply, %{state | status: :speaking}}
  end

  # Brain Finished Generation
  @impl true
  def handle_info(:brain_turn_complete, state) do
    Logger.debug("[Session:#{state.call_id}] Brain turn complete")
    {:noreply, state}
  end

  # Synthesized Audio Chunk from TTS
  @impl true
  def handle_info({:tts_audio_chunk, mulaw_chunk}, state) do
    if state.status == :speaking do
      # Push directly to caller transport
      send(state.transport_pid, {:send_audio, mulaw_chunk})
    end

    {:noreply, state}
  end

  # TTS Playback Finished for Turn
  @impl true
  def handle_info({:tts_turn_completed, _call_id}, state) do
    Logger.debug("[Session:#{state.call_id}] TTS completed playback for turn")
    {:noreply, %{state | status: :listening}}
  end

  # End Call Requested by Brain
  @impl true
  def handle_info(:brain_end_call, state) do
    Logger.info("[Session:#{state.call_id}] Brain requested call termination")
    send(state.transport_pid, :hangup)
    {:stop, :normal, state}
  end

  # Action Requested by Brain / Agent (Transfer, Hangup, Custom Tool Action)
  @impl true
  def handle_info({:brain_action, :hangup, _payload}, state) do
    Logger.info("[Session:#{state.call_id}] Brain requested call termination")
    send(state.transport_pid, :hangup)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:brain_action, :transfer, %{"target" => dest}}, state) do
    Logger.info("[Session:#{state.call_id}] Brain requested call transfer to #{dest}")
    send(state.transport_pid, {:transfer, dest})
    {:noreply, state}
  end

  @impl true
  def handle_info({:brain_action, action, payload}, state) do
    Logger.info("[Session:#{state.call_id}] Brain requested action #{action}: #{inspect(payload)}")
    {:noreply, state}
  end

  # Caller Pressed Keypad Digit (DTMF)
  @impl true
  def handle_info({:caller_dtmf, digit}, state) do
    Logger.info("[Session:#{state.call_id}] Inbound DTMF touch-tone received: #{digit}")

    # Forward to Native LLM Agent or external Brain Bridge
    cond do
      state.agent_pid ->
        LLMAgent.user_turn(state.agent_pid, "The caller pressed key #{digit} on their phone keypad.")

      state.brain_pid ->
        BrainBridge.send_user_turn(state.brain_pid, "DTMF: #{digit}")

      true ->
        :ok
    end

    {:noreply, %{state | status: :thinking}}
  end

  # Telephony Playback Mark Synchronizer (Caller Handset Playout Complete)
  @impl true
  def handle_info({:carrier_mark, mark_name}, state) do
    Logger.debug("[Session:#{state.call_id}] Telephony playout completed for mark: #{mark_name}")
    {:noreply, %{state | status: :listening}}
  end

  # STT Silence Endpointing Detected (Speech Ended)
  @impl true
  def handle_info({:stt_speech_ended, _call_id}, state) do
    Logger.debug("[Session:#{state.call_id}] Speech endpointing detected (silence onset)")
    {:noreply, state}
  end

  # Carrier Stream Error
  @impl true
  def handle_info({:carrier_error, reason}, state) do
    Logger.error("[Session:#{state.call_id}] Carrier stream error: #{inspect(reason)}")
    {:noreply, state}
  end

  # Caller Hung Up
  @impl true
  def handle_info({:caller_hangup, reason}, state) do
    Logger.info("[Session:#{state.call_id}] Caller hung up: #{inspect(reason)}")
    if state.agent_pid, do: LLMAgent.abort(state.agent_pid)
    if state.brain_pid, do: BrainBridge.send_call_ended(state.brain_pid, reason)
    {:stop, :normal, %{state | status: :ended}}
  end

  # Telephony Transport Process Died Unexpectedly
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{transport_monitor: ref} = state) do
    Logger.warning("[Session:#{state.call_id}] Telephony transport process terminated unexpectedly: #{inspect(reason)}")
    if state.brain_pid, do: BrainBridge.send_call_ended(state.brain_pid, "transport-down")
    {:stop, :normal, %{state | status: :ended}}
  end

  # Child Process Crashed or Exited
  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    Logger.warning("[Session:#{state.call_id}] Child process #{inspect(pid)} exited: #{inspect(reason)}")
    {:noreply, state}
  end

  # Dynamic Call Reconfiguration (API / GenServer.call)
  @impl true
  def handle_call({:reconfigure, new_config}, _from, state) do
    updated_state = apply_reconfiguration(state, new_config)
    {:reply, :ok, updated_state}
  end

  # Dynamic Call Reconfiguration (Brain Signal from NestJS)
  @impl true
  def handle_info({:brain_reconfigure, new_config}, state) do
    updated_state = apply_reconfiguration(state, new_config)
    {:noreply, updated_state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("[Session:#{state.call_id}] Terminating call session (reason: #{inspect(reason)})")

    # Cleanly stop clients
    if state.agent_pid, do: LLMAgent.abort(state.agent_pid)
    if state.stt_handle, do: STTStreamer.close(state.stt_handle)
    if state.tts_handle, do: TTSStreamer.abort(state.tts_handle)

    :ok
  end

  # ==========================================
  # Reconfiguration Helpers
  # ==========================================

  defp apply_reconfiguration(state, new_config) do
    Logger.info("[Session:#{state.call_id}] Hot-swapping call configuration: #{inspect(new_config)}")

    normalized = normalize_config(new_config)
    merged_config = Keyword.merge(state.config, normalized)

    # 1. Hot-swap STT if provider or language changed
    new_stt_handle =
      if should_swap_stt?(state.config, merged_config) do
        Logger.info("[Session:#{state.call_id}] Swapping STT provider to #{inspect(merged_config[:stt_provider])}")
        stop_client(state.stt_handle)

        case STTStreamer.start_link(self(), state.call_id, merged_config) do
          {:ok, handle} -> handle
          {:error, err} ->
            Logger.error("[Session:#{state.call_id}] Failed to swap STT: #{inspect(err)}")
            state.stt_handle
        end
      else
        state.stt_handle
      end

    # 2. Hot-swap TTS if provider, voice_id, model_id, or speaker changed
    new_tts_handle =
      if should_swap_tts?(state.config, merged_config) do
        Logger.info("[Session:#{state.call_id}] Swapping TTS provider to #{inspect(merged_config[:tts_provider])}")
        stop_client(state.tts_handle)

        case TTSStreamer.start_link(self(), state.call_id, merged_config) do
          {:ok, handle} -> handle
          {:error, err} ->
            Logger.error("[Session:#{state.call_id}] Failed to swap TTS: #{inspect(err)}")
            state.tts_handle
        end
      else
        state.tts_handle
      end

    # 3. Update Native LLM Agent if LLM settings changed
    if state.agent_pid && should_update_agent?(state.config, merged_config) do
      Logger.info("[Session:#{state.call_id}] Updating Native LLM Agent config")
      LLMAgent.update_config(state.agent_pid, merged_config)
    end

    %{state | stt_handle: new_stt_handle, tts_handle: new_tts_handle, config: merged_config}
  end

  defp stop_client({_mod, pid}) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
  end

  defp stop_client(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
  end

  defp stop_client(_), do: :ok

  defp should_swap_stt?(old_config, new_config) do
    old_config[:stt_provider] != new_config[:stt_provider] or
      old_config[:language_code] != new_config[:language_code]
  end

  defp should_swap_tts?(old_config, new_config) do
    old_config[:tts_provider] != new_config[:tts_provider] or
      old_config[:voice_id] != new_config[:voice_id] or
      old_config[:speaker] != new_config[:speaker] or
      old_config[:model_id] != new_config[:model_id]
  end

  defp should_update_agent?(old_config, new_config) do
    old_config[:llm_provider] != new_config[:llm_provider] or
      old_config[:llm_model] != new_config[:llm_model] or
      old_config[:system_prompt] != new_config[:system_prompt]
  end

  defp normalize_config(map) when is_map(map) do
    Enum.reduce(map, [], fn
      {"stt_provider", v}, acc -> [{:stt_provider, to_provider_atom(v)} | acc]
      {"tts_provider", v}, acc -> [{:tts_provider, to_provider_atom(v)} | acc]
      {"llm_provider", v}, acc -> [{:llm_provider, to_provider_atom(v)} | acc]
      {"llm_model", v}, acc -> [{:llm_model, v} | acc]
      {"system_prompt", v}, acc -> [{:system_prompt, v} | acc]
      {"brain_mode", v}, acc -> [{:brain_mode, to_provider_atom(v)} | acc]
      {"language_code", v}, acc -> [{:language_code, v} | acc]
      {"language", v}, acc -> [{:language_code, v} | acc]
      {"voice_id", v}, acc -> [{:voice_id, v} | acc]
      {"speaker", v}, acc -> [{:speaker, v} | acc]
      {"model_id", v}, acc -> [{:model_id, v} | acc]
      {"greeting", v}, acc -> [{:greeting, v} | acc]
      {k, v}, acc when is_atom(k) -> [{k, v} | acc]
      _other, acc -> acc
    end)
  end

  defp normalize_config(list) when is_list(list), do: list

  defp to_provider_atom(val) when is_atom(val), do: val
  defp to_provider_atom(val) when is_binary(val) do
    case String.downcase(String.trim(val)) do
      "deepgram" -> :deepgram
      "assemblyai" -> :assemblyai
      "sarvam" -> :sarvam
      "elevenlabs" -> :elevenlabs
      "cartesia" -> :cartesia
      "fishaudio" -> :fishaudio
      "fish_audio" -> :fishaudio
      "whisper" -> :whisper
      "groq" -> :groq
      "cerebras" -> :cerebras
      "openai" -> :openai
      "anthropic" -> :anthropic
      "deepseek" -> :deepseek
      "ollama" -> :ollama
      "native" -> :native
      "bridge" -> :bridge
      _ -> String.to_atom(val)
    end
  end
end
