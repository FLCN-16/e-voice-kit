defmodule EVoiceKit.Pipeline.SessionTest do
  use ExUnit.Case, async: true
  alias EVoiceKit.Pipeline.{Buffer, Session}

  describe "Call Session buffer & config" do
    test "Buffer packetizes and flushes audio" do
      buf = Buffer.new(160)
      {packets, buf1} = Buffer.push(buf, :binary.copy(<<0xFF>>, 320))

      assert length(packets) == 2
      assert byte_size(hd(packets)) == 160
      assert Buffer.pending_bytes(buf1) == 0

      # Push remainder and flush
      {_p, buf2} = Buffer.push(buf1, :binary.copy(<<0xFF>>, 50))
      assert Buffer.pending_bytes(buf2) == 50

      flushed = Buffer.flush(buf2)
      assert Buffer.pending_bytes(flushed) == 0
    end

    test "Session handles DTMF, carrier marks, and speech endpointing" do
      state = %Session{
        call_id: "test_call",
        transport_pid: self(),
        status: :speaking
      }

      # 1. DTMF Keypad Tone
      assert {:noreply, updated_state} = Session.handle_info({:caller_dtmf, "5"}, state)
      assert updated_state.status == :thinking

      # 2. Carrier Playback Mark Complete
      assert {:noreply, listening_state} = Session.handle_info({:carrier_mark, "greeting_done"}, state)
      assert listening_state.status == :listening

      # 3. Speech Endpointing Detected
      assert {:noreply, ^state} = Session.handle_info({:stt_speech_ended, "test_call"}, state)

      # 4. Carrier Stream Error
      assert {:noreply, ^state} = Session.handle_info({:carrier_error, "network_glitch"}, state)
    end
  end
end
