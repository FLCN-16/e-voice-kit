defmodule EVoiceKit.Transports.WebSocketCarrier do
  @moduledoc """
  Abstract base class / macro for building WebSocket-based Telephony Carrier Transports.

  Implements the full Bandit `WebSock` protocol, process lifecycle, dynamic call session
  supervision, bidirectional G.711 μ-law routing, DTMF touch-tone extraction, playback
  synchronization marks, and barge-in synchronization.

  Any developer can implement a new carrier (e.g. Vonage, Twilio, Telnyx, Plivo)
  by simply writing `use EVoiceKit.Transports.WebSocketCarrier` and implementing
  the carrier-specific wire protocol encoders and decoders.
  """

  defmacro __using__(_opts) do
    quote do
      @behaviour WebSock
      @behaviour EVoiceKit.Providers.Carrier
      require Logger
      alias EVoiceKit.Pipeline.SessionSupervisor
      alias EVoiceKit.Providers.Events

      defstruct call_id: nil,
                session_pid: nil,
                carrier_data: %{}

      # ------------------------------------------------------------------------
      # WebSock Callbacks
      # ------------------------------------------------------------------------

      @impl WebSock
      def init(args) do
        case init_carrier(args) do
          {:ok, carrier_data} ->
            {:ok, %__MODULE__{carrier_data: carrier_data}}

          {:stop, reason} ->
            {:stop, reason}
        end
      end

      @impl WebSock
      def handle_in({:text, raw_text}, state) do
        case Jason.decode(raw_text) do
          {:ok, payload} ->
            dispatch_carrier_event(payload, state)

          {:error, err} ->
            Logger.warning("[#{carrier_name()}] Invalid JSON received: #{inspect(err)}")
            {:ok, state}
        end
      end

      @impl WebSock
      def handle_in({:binary, binary_data}, state) do
        dispatch_carrier_event(binary_data, state)
      end

      # ------------------------------------------------------------------------
      # Telephony Session Callbacks (Messages from EVoiceKit.Pipeline.Session)
      # ------------------------------------------------------------------------

      # Outbound Synthesized Audio from Agent
      @impl WebSock
      def handle_info({:send_audio, mulaw_chunk}, state) do
        case encode_media_frame(mulaw_chunk, state) do
          {:reply, frame, new_state} ->
            {:reply, :ok, frame, new_state}

          {:ok, new_state} ->
            {:ok, new_state}

          :ignore ->
            {:ok, state}
        end
      end

      # Playback Synchronization Mark request from Session
      @impl WebSock
      def handle_info({:send_mark, mark_name}, state) do
        case encode_mark_frame(mark_name, state) do
          {:reply, frame, new_state} ->
            {:reply, :ok, frame, new_state}

          {:ok, new_state} ->
            {:ok, new_state}

          :ignore ->
            {:ok, state}
        end
      end

      # Barge-in Interruption: Flush Carrier Audio Buffer
      @impl WebSock
      def handle_info(:clear_audio, state) do
        Logger.debug("[#{carrier_name()}:#{state.call_id}] Flushing carrier playback buffer (barge-in)")

        case encode_clear_frame(state) do
          {:reply, frame, new_state} ->
            {:reply, :ok, frame, new_state}

          {:ok, new_state} ->
            {:ok, new_state}

          :ignore ->
            {:ok, state}
        end
      end

      # Call Hangup requested by Agent Brain
      @impl WebSock
      def handle_info(:hangup, state) do
        Logger.info("[#{carrier_name()}:#{state.call_id}] Disconnecting call per agent request")

        case encode_hangup_frame(state) do
          {:reply, frame, new_state} ->
            {:reply, :ok, frame, new_state}

          {:stop, reason, new_state} ->
            {:stop, reason, new_state}

          :ignore ->
            {:stop, :normal, state}
        end
      end

      # Call Transfer requested by Agent Brain
      @impl WebSock
      def handle_info({:transfer, destination}, state) do
        Logger.info("[#{carrier_name()}:#{state.call_id}] Transferring call to #{destination}")

        case encode_transfer_frame(destination, state) do
          {:reply, frame, new_state} ->
            {:reply, :ok, frame, new_state}

          {:ok, new_state} ->
            {:ok, new_state}

          :ignore ->
            {:ok, state}
        end
      end

      # Catch-all for other process messages
      @impl WebSock
      def handle_info(other, state) do
        handle_custom_info(other, state)
      end

      @impl WebSock
      def terminate(reason, state) do
        Logger.info("[#{carrier_name()}:#{state.call_id}] Connection terminated: #{inspect(reason)}")
        terminate_carrier(reason, state)
        :ok
      end

      # ------------------------------------------------------------------------
      # Exhaustive Internal Event Dispatcher
      # ------------------------------------------------------------------------

      defp dispatch_carrier_event(payload, state) do
        # 1. Run through canonical carrier event normalizer
        case Events.normalize_carrier_event(payload) do
          :call_stop ->
            Logger.info("[#{carrier_name()}:#{state.call_id}] Carrier call stopped")
            if state.session_pid, do: send(state.session_pid, {:caller_hangup, "carrier-stop"})
            {:stop, :normal, state}

          {:dtmf, digit} ->
            Logger.info("[#{carrier_name()}:#{state.call_id}] DTMF touch-tone received: #{digit}")
            if state.session_pid, do: send(state.session_pid, {:caller_dtmf, digit})
            {:ok, state}

          {:mark, mark_name} ->
            Logger.debug("[#{carrier_name()}:#{state.call_id}] Handset finished playing mark: #{mark_name}")
            if state.session_pid, do: send(state.session_pid, {:carrier_mark, mark_name})
            {:ok, state}

          :clear ->
            Logger.debug("[#{carrier_name()}:#{state.call_id}] Carrier acknowledged buffer clear")
            {:ok, state}

          :connected ->
            Logger.debug("[#{carrier_name()}] Telephony socket handshake confirmed")
            {:ok, state}

          {:error, err} ->
            Logger.error("[#{carrier_name()}:#{state.call_id}] Carrier error: #{inspect(err)}")
            if state.session_pid, do: send(state.session_pid, {:carrier_error, err})
            {:ok, state}

          _other ->
            # 2. Check vendor stop / disconnect event
            case parse_stop_event(payload, state) do
              {:hangup, reason} ->
                Logger.info("[#{carrier_name()}:#{state.call_id}] Caller hung up (#{reason})")
                if state.session_pid, do: send(state.session_pid, {:caller_hangup, reason})
                {:stop, :normal, state}

              :ignore ->
                # 3. Check for Call Setup / Start Event
                case parse_start_event(payload, state) do
                  {:ok, call_id, session_opts, new_state} ->
                    Logger.info("[#{carrier_name()}:#{call_id}] Initializing session with opts: #{inspect(session_opts)}")

                    full_opts = Keyword.put(session_opts, :transport_pid, self())
                    full_opts = Keyword.put_new(full_opts, :call_id, call_id)

                    case SessionSupervisor.start_session(full_opts) do
                      {:ok, session_pid} ->
                        {:ok, %{new_state | call_id: call_id, session_pid: session_pid}}

                      {:error, err} ->
                        Logger.error("[#{carrier_name()}:#{call_id}] Failed to spawn Session GenServer: #{inspect(err)}")
                        {:stop, {:session_spawn_failed, err}, new_state}
                    end

                  :ignore ->
                    # 4. Check for Inbound Media (Audio)
                    case parse_media_event(payload, state) do
                      {:ok, mulaw_audio, new_state} ->
                        if state.session_pid do
                          send(state.session_pid, {:caller_audio, mulaw_audio})
                        end

                        {:ok, new_state}

                      :ignore ->
                        handle_custom_in(payload, state)

                      {:error, reason} ->
                        Logger.debug("[#{carrier_name()}] Error parsing media: #{inspect(reason)}")
                        {:ok, state}
                    end

                  {:error, reason} ->
                    Logger.error("[#{carrier_name()}] Error parsing start event: #{inspect(reason)}")
                    {:ok, state}
                end
            end
        end
      end

      # ------------------------------------------------------------------------
      # Default Overridable Implementations
      # ------------------------------------------------------------------------

      def init_carrier(_args), do: {:ok, %{}}

      def parse_stop_event(%{"event" => "stop"}, _state), do: {:hangup, "carrier-stop"}
      def parse_stop_event(%{"event" => "disconnect"}, _state), do: {:hangup, "carrier-disconnect"}
      def parse_stop_event(_other, _state), do: :ignore

      def encode_clear_frame(_state), do: :ignore

      def encode_mark_frame(_mark_name, _state), do: :ignore

      def encode_hangup_frame(state), do: {:stop, :normal, state}

      def encode_transfer_frame(_destination, _state), do: :ignore

      def handle_custom_in(_payload, state), do: {:ok, state}

      def handle_custom_info(_msg, state), do: {:ok, state}

      def terminate_carrier(_reason, _state), do: :ok

      defoverridable init_carrier: 1,
                     parse_stop_event: 2,
                     encode_clear_frame: 1,
                     encode_mark_frame: 2,
                     encode_hangup_frame: 1,
                     encode_transfer_frame: 2,
                     handle_custom_in: 2,
                     handle_custom_info: 2,
                     terminate_carrier: 2
    end
  end
end
