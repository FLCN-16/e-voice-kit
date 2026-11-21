defmodule EVoiceKit.Signaling.WebSocket do
  @moduledoc """
  WebSock behaviour implementation for native E-Voice-Kit WebRTC signaling.
  Served by Bandit via `WebSockAdapter` at `/rtc/v1`.

  Receives and responds using the fixed 28-byte `EVK1` binary envelope.
  """

  @behaviour WebSock
  require Logger

  alias EVoiceKit.Signaling.Session

  @impl true
  def init(opts) do
    {:ok, session_pid} = Session.start_link(opts)
    {:ok, %{session_pid: session_pid}}
  end

  @impl true
  def handle_in({binary_frame, opcode: :binary}, %{session_pid: pid} = state) do
    case Session.handle_frame(pid, binary_frame) do
      {:ok, response_binaries} ->
        frames = Enum.map(response_binaries, fn bin -> {:binary, bin} end)
        {:push, frames, state}

      {:error, _reason, response_binaries} ->
        frames = Enum.map(response_binaries, fn bin -> {:binary, bin} end)
        {:push, frames, state}

      {:error, reason} ->
        Logger.warning("WebSocket signaling error: #{inspect(reason)}")
        {:ok, state}
    end
  end

  # Handle text frames by logging warning (native protocol expects binary EVK1 frames)
  @impl true
  def handle_in({_text_frame, opcode: :text}, state) do
    Logger.warning("Received unexpected text frame on native signaling endpoint; EVK1 binary required")
    {:ok, state}
  end

  @impl true
  def handle_info({:push_message, binary}, state) do
    {:push, {:binary, binary}, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, %{session_pid: pid}) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal)
    end

    :ok
  end
end
