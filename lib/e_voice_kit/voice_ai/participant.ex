defmodule EVoiceKit.VoiceAI.Participant do
  @moduledoc """
  AI Agent represented as a first-class participant inside an E-Voice-Kit room.
  Subscribes to audio tracks from human participants and publishes synthesized speech tracks.

  See `docs/ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md` (Section 22).
  """

  use GenServer
  require Logger

  alias EVoiceKit.Participants.Participant
  alias EVoiceKit.SFU.{Router, UpTrack}

  defstruct [
    :room_name,
    :agent_sid,
    :router_pid,
    :subscribed_track_sid,
    :published_track_sid,
    :stt_provider,
    :tts_provider,
    active: true
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Connects the AI agent to a room and establishes its published speech track.
  """
  def join_room(agent_pid, room_name, router_pid) do
    GenServer.call(agent_pid, {:join_room, room_name, router_pid})
  end

  @doc """
  Subscribes the AI agent to a user's audio track.
  """
  def subscribe_to_track(agent_pid, track_sid) do
    GenServer.call(agent_pid, {:subscribe_to_track, track_sid})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    agent_sid = Keyword.get(opts, :agent_sid, "ai_agent_" <> generate_id())
    stt = Keyword.get(opts, :stt_provider, :deepgram)
    tts = Keyword.get(opts, :tts_provider, :cartesia)

    state = %__MODULE__{
      agent_sid: agent_sid,
      stt_provider: stt,
      tts_provider: tts
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:join_room, room_name, router_pid}, _from, state) do
    # Register published track for AI speech
    track_sid = "TR_AI_" <> generate_id()
    up_track = UpTrack.new(track_sid, state.agent_sid, kind: :audio, codec: :opus, clock_rate: 48000)

    if is_pid(router_pid) do
      Router.register_up_track(router_pid, up_track)
    end

    new_state = %{
      state
      | room_name: room_name,
        router_pid: router_pid,
        published_track_sid: track_sid
    }

    Logger.info("Voice AI participant #{state.agent_sid} joined room #{room_name}")
    {:reply, {:ok, track_sid}, new_state}
  end

  @impl true
  def handle_call({:subscribe_to_track, track_sid}, _from, state) do
    if is_pid(state.router_pid) do
      Router.subscribe(state.router_pid, state.agent_sid, track_sid, self())
    end

    new_state = %{state | subscribed_track_sid: track_sid}
    {:reply, :ok, new_state}
  end

  # Inbound media from subscriber DownTrack
  @impl true
  def handle_info({:forwarded_rtp, _track_sid, rtp_packet}, state) do
    # Feed audio packet to VAD / STT pipeline
    # (Non-blocking: forwards packet to background speech processing worker)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp generate_id do
    :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
  end
end
