defmodule EVoiceKit.Rooms.RoomCoordinatorTest do
  use ExUnit.Case, async: true

  alias EVoiceKit.Rooms.RoomCoordinator

  setup do
    # Start an un-named RoomCoordinator for test isolation
    room_name = "test_room_#{:crypto.strong_rand_bytes(4) |> Base.encode16()}"
    {:ok, pid} = GenServer.start_link(RoomCoordinator, {room_name, [max_participants: 2]})
    %{coordinator: pid, room_name: room_name}
  end

  describe "RoomCoordinator lifecycle & operations" do
    test "admits participants and returns snapshot", %{coordinator: coord} do
      assert {:ok, alice} = RoomCoordinator.join_participant(coord, "alice")
      assert alice.identity == "alice"
      assert is_binary(alice.participant_sid)

      assert {:ok, bob} = RoomCoordinator.join_participant(coord, "bob")
      assert bob.identity == "bob"

      participants = RoomCoordinator.list_participants(coord)
      assert length(participants) == 2
      identities = Enum.map(participants, & &1.identity)
      assert "alice" in identities
      assert "bob" in identities
    end

    test "handles join idempotency", %{coordinator: coord} do
      assert {:ok, alice1} = RoomCoordinator.join_participant(coord, "alice")
      assert {:ok, alice2} = RoomCoordinator.join_participant(coord, "alice")
      assert alice1.participant_sid == alice2.participant_sid
      assert length(RoomCoordinator.list_participants(coord)) == 1
    end

    test "enforces max participants limit", %{coordinator: coord} do
      assert {:ok, _} = RoomCoordinator.join_participant(coord, "user1")
      assert {:ok, _} = RoomCoordinator.join_participant(coord, "user2")
      assert {:error, :room_full} = RoomCoordinator.join_participant(coord, "user3")
    end

    test "publishes and unpublishes tracks", %{coordinator: coord} do
      {:ok, alice} = RoomCoordinator.join_participant(coord, "alice")
      sid = alice.participant_sid

      assert {:ok, track_sid} =
               RoomCoordinator.publish_track(coord, sid, %{kind: "audio", source: "microphone"})

      assert String.starts_with?(track_sid, "TR_")

      # Unpublish track
      assert :ok = RoomCoordinator.unpublish_track(coord, track_sid)
    end

    test "cleans up participant when session process dies", %{coordinator: coord} do
      # Spawn a temporary process representing participant session
      test_session = spawn(fn -> receive do: (:stop -> :ok) end)

      {:ok, user} = RoomCoordinator.join_participant(coord, "transient_user", session_pid: test_session)
      assert length(RoomCoordinator.list_participants(coord)) == 1

      # Kill session process
      Process.exit(test_session, :kill)
      :timer.sleep(20)

      # Coordinator should automatically remove dead participant
      assert length(RoomCoordinator.list_participants(coord)) == 0
    end
  end
end
