defmodule EVoiceKit.Rooms.RoomCoordinator do
  @moduledoc """
  Control-plane coordinator for an active communication room.
  Manages participant admission, presence, track metadata, and lifecycle events.

  CRITICAL PERFORMANCE RULE (Technical Design Section 6):
  RoomCoordinator is a control-plane owner only. It must NEVER serialize or handle
  individual RTP media packets.
  """

  use GenServer
  require Logger

  alias EVoiceKit.Participants.Participant
  alias EVoiceKit.Rooms.{Registry, Room}

  defstruct [
    :room,
    participants: %{},
    identities: %{},
    tracks: %{},
    monitors: %{}
  ]

  # --- Client API ---

  def start_link(room_name, opts \\ []) when is_binary(room_name) do
    name = Keyword.get(opts, :name, Registry.via_tuple(room_name))
    GenServer.start_link(__MODULE__, {room_name, opts}, name: name)
  end

  @doc """
  Admits a participant into the room with idempotency checks and capacity limits.
  """
  def join_participant(server, identity, opts \\ []) do
    call(server, {:join_participant, identity, opts})
  end

  @doc """
  Removes a participant from the room and tears down their published tracks.
  """
  def leave_participant(server, participant_sid) do
    call(server, {:leave_participant, participant_sid})
  end

  @doc """
  Registers a published track metadata under the participant.
  """
  def publish_track(server, participant_sid, track_params) do
    call(server, {:publish_track, participant_sid, track_params})
  end

  @doc """
  Unpublishes a track from the room.
  """
  def unpublish_track(server, track_sid) do
    call(server, {:unpublish_track, track_sid})
  end

  @doc """
  Returns current room snapshot.
  """
  def get_room(server) do
    call(server, :get_room)
  end

  @doc """
  Lists all active participants in the room.
  """
  def list_participants(server) do
    call(server, :list_participants)
  end

  # Helper for calling by pid or room name
  defp call(server, msg) when is_pid(server), do: GenServer.call(server, msg)

  defp call(room_name, msg) when is_binary(room_name) do
    case Registry.lookup(room_name) do
      {:ok, pid} -> GenServer.call(pid, msg)
      err -> err
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init({room_name, opts}) do
    room = Room.new(room_name, opts)
    Logger.info("RoomCoordinator started for room #{room_name} (sid: #{room.room_sid})")

    state = %__MODULE__{
      room: room,
      participants: %{},
      identities: %{},
      tracks: %{},
      monitors: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_room, _from, state) do
    {:reply, state.room, state}
  end

  @impl true
  def handle_call(:list_participants, _from, state) do
    participants = Map.values(state.participants)
    {:reply, participants, state}
  end

  @impl true
  def handle_call({:join_participant, identity, opts}, _from, state) do
    cond do
      map_size(state.participants) >= state.room.max_participants ->
        {:reply, {:error, :room_full}, state}

      Map.has_key?(state.identities, identity) ->
        # Idempotent re-join: return existing participant
        existing_sid = Map.get(state.identities, identity)
        participant = Map.get(state.participants, existing_sid)
        {:reply, {:ok, participant}, state}

      true ->
        participant = Participant.new(identity, opts)
        sid = participant.participant_sid

        # Monitor participant session pid if supplied
        monitors =
          if is_pid(participant.session_pid) do
            ref = Process.monitor(participant.session_pid)
            Map.put(state.monitors, ref, sid)
          else
            state.monitors
          end

        new_participants = Map.put(state.participants, sid, %{participant | state: :connected})
        new_identities = Map.put(state.identities, identity, sid)

        new_state = %{
          state
          | participants: new_participants,
            identities: new_identities,
            monitors: monitors
        }

        Logger.info("Participant joined room #{state.room.name}: #{identity} (#{sid})")
        {:reply, {:ok, participant}, new_state}
    end
  end

  @impl true
  def handle_call({:leave_participant, participant_sid}, _from, state) do
    new_state = remove_participant(state, participant_sid)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:publish_track, participant_sid, track_params}, _from, state) do
    case Map.get(state.participants, participant_sid) do
      nil ->
        {:reply, {:error, :participant_not_found}, state}

      participant ->
        track_sid = generate_sid("TR_")

        track_info = %{
          track_sid: track_sid,
          publisher_sid: participant_sid,
          kind: Map.get(track_params, :kind, "audio"),
          source: Map.get(track_params, :source, "microphone"),
          muted: false
        }

        updated_participant = %{
          participant
          | tracks: Map.put(participant.tracks, track_sid, track_info)
        }

        new_state = %{
          state
          | participants: Map.put(state.participants, participant_sid, updated_participant),
            tracks: Map.put(state.tracks, track_sid, track_info)
        }

        Logger.info("Track published in #{state.room.name}: #{track_sid} by #{participant_sid}")
        {:reply, {:ok, track_sid}, new_state}
    end
  end

  @impl true
  def handle_call({:unpublish_track, track_sid}, _from, state) do
    case Map.get(state.tracks, track_sid) do
      nil ->
        {:reply, :ok, state}

      track_info ->
        publisher_sid = track_info.publisher_sid

        updated_participants =
          case Map.get(state.participants, publisher_sid) do
            nil ->
              state.participants

            participant ->
              Map.put(
                state.participants,
                publisher_sid,
                %{participant | tracks: Map.delete(participant.tracks, track_sid)}
              )
          end

        new_state = %{
          state
          | participants: updated_participants,
            tracks: Map.delete(state.tracks, track_sid)
        }

        {:reply, :ok, new_state}
    end
  end

  # Handle participant process failure
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {participant_sid, new_monitors} ->
        Logger.info(
          "Participant #{participant_sid} session process died (#{inspect(reason)}); cleaning up"
        )

        new_state = remove_participant(%{state | monitors: new_monitors}, participant_sid)
        {:noreply, new_state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal Helpers ---

  defp remove_participant(state, participant_sid) do
    case Map.pop(state.participants, participant_sid) do
      {nil, _} ->
        state

      {participant, new_participants} ->
        new_identities = Map.delete(state.identities, participant.identity)

        # Remove published tracks owned by this participant
        new_tracks =
          Enum.reduce(participant.tracks, state.tracks, fn {track_sid, _}, acc ->
            Map.delete(acc, track_sid)
          end)

        Logger.info("Participant left room #{state.room.name}: #{participant.identity}")

        %{
          state
          | participants: new_participants,
            identities: new_identities,
            tracks: new_tracks
        }
    end
  end

  defp generate_sid(prefix) do
    prefix <> (:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower))
  end
end
