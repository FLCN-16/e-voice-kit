defmodule EVoiceKit.Clients.BrainBridge do
  @moduledoc """
  Duplex IPC WebSocket client connecting Elixir Voice Gateway to the NestJS Cognitive Brain.

  Translates real-time telephony turn events to the agent brain, and receives
  streaming tokens, instant fillers, initial greetings, and tool action signals from NestJS.
  """

  use WebSockex
  require Logger

  defstruct session_pid: nil,
            call_id: nil,
            url: nil

  @doc """
  Starts a brain bridge WebSocket connection for an active call with full multi-tenancy context.
  """
  def start_link(session_pid, call_id, opts \\ []) do
    base_url =
      opts[:url] ||
        Application.get_env(:e_voice_kit, :brain_bridge_url, "ws://localhost:3000/voice-bridge")

    query_params =
      %{
        "call_id" => call_id,
        "tenant_id" => opts[:tenant_id],
        "assistant_id" => opts[:assistant_id],
        "caller_number" => opts[:caller_number],
        "dialed_number" => opts[:dialed_number]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> URI.encode_query()

    url =
      if query_params != "" do
        "#{base_url}?#{query_params}"
      else
        "#{base_url}?call_id=#{call_id}"
      end

    state = %__MODULE__{
      session_pid: session_pid,
      call_id: call_id,
      url: url
    }

    WebSockex.start_link(url, __MODULE__, state)
  end

  @doc """
  Notifies the NestJS brain that the user has completed an utterance.
  """
  def send_user_turn(pid, transcript, confidence \\ 1.0) do
    if is_pid(pid) and Process.alive?(pid) do
      payload = %{
        "event" => "user_turn",
        "channel" => "voice",
        "transcript" => transcript,
        "confidence" => confidence,
        "timestamp" => System.system_time(:millisecond)
      }

      WebSockex.send_frame(pid, {:text, Jason.encode!(payload)})
    else
      {:error, :bridge_unavailable}
    end
  end

  @doc """
  Notifies the NestJS brain of an instant barge-in / interruption,
  triggering upstream AbortController.
  """
  def send_interrupt(pid) do
    if is_pid(pid) and Process.alive?(pid) do
      payload = %{
        "event" => "interrupt",
        "timestamp" => System.system_time(:millisecond)
      }

      WebSockex.send_frame(pid, {:text, Jason.encode!(payload)})
    else
      {:error, :bridge_unavailable}
    end
  end

  @doc """
  Notifies the NestJS brain of call termination.
  """
  def send_call_ended(pid, reason) do
    if is_pid(pid) and Process.alive?(pid) do
      payload = %{
        "event" => "call_ended",
        "reason" => to_string(reason),
        "timestamp" => System.system_time(:millisecond)
      }

      WebSockex.send_frame(pid, {:text, Jason.encode!(payload)})
    else
      {:error, :bridge_unavailable}
    end
  end

  # WebSockex Callbacks

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("[Brain:#{state.call_id}] Connected to NestJS Cognitive Brain")
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      # Initial Session Handshake from NestJS
      {:ok, %{"event" => "init_session", "config" => config}} ->
        Logger.info("[Brain:#{state.call_id}] Received session initialization config from NestJS")
        send(state.session_pid, {:brain_init_session, config})
        {:ok, state}

      # Initial Greeting or Direct Speech
      {:ok, %{"event" => "greeting", "text" => greeting}} ->
        Logger.info("[Brain:#{state.call_id}] Received initial greeting: #{inspect(greeting)}")
        send(state.session_pid, {:brain_greeting, greeting})
        {:ok, state}

      # Streaming Token
      {:ok, %{"event" => "token", "text" => token}} ->
        send(state.session_pid, {:brain_token, token})
        {:ok, state}

      # Immediate Conversational Filler
      {:ok, %{"event" => "filler", "text" => filler}} ->
        Logger.info("[Brain:#{state.call_id}] Received filler from brain: #{inspect(filler)}")
        send(state.session_pid, {:brain_filler, filler})
        {:ok, state}

      # Generation Complete
      {:ok, %{"event" => "turn_complete"}} ->
        send(state.session_pid, :brain_turn_complete)
        {:ok, state}

      # Dynamic Mid-Call Reconfiguration
      {:ok, %{"event" => "reconfigure"} = config_payload} ->
        Logger.info("[Brain:#{state.call_id}] Received dynamic reconfigure request from brain")
        send(state.session_pid, {:brain_reconfigure, config_payload})
        {:ok, state}

      # End Call
      {:ok, %{"event" => "end_call"}} ->
        send(state.session_pid, :brain_end_call)
        {:ok, state}

      {:ok, other} ->
        Logger.debug("[Brain:#{state.call_id}] Unhandled brain event: #{inspect(other)}")
        {:ok, state}

      {:error, err} ->
        Logger.warning("[Brain:#{state.call_id}] Failed to decode brain message: #{inspect(err)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.info("[Brain:#{state.call_id}] Brain bridge disconnected: #{inspect(reason)}")
    {:ok, state}
  end
end
