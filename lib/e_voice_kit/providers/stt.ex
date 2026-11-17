defmodule EVoiceKit.Providers.STT do
  @moduledoc """
  Pluggable behaviour and abstract base class macro for Speech-to-Text (STT) providers.

  Any community or custom STT provider can be created by adopting this behaviour or
  by writing `use EVoiceKit.Providers.STT`, which handles all WebSockex connections,
  audio transcoding (G.711 μ-law to 16-bit linear PCM if needed), canonical event
  normalization (`:speech_started`, `:speech_ended`, `:transcript`), and message
  routing to the active call session automatically.

  ## Canonical Event Mapping
  Regardless of vendor naming (Deepgram's `"SpeechStarted"`, Whisper's `"vad_started"`,
  AssemblyAI's `"PartialTranscript"`, or OpenAI's `"input_audio_buffer.speech_started"`),
  all events resolve to unified canonical enums via `EVoiceKit.Providers.Events`.

  ## Example Implementation

      defmodule EVoiceKit.Clients.MyCustomSTT do
        use EVoiceKit.Providers.STT, audio_format: :pcm_16

        @impl EVoiceKit.Providers.STT
        def build_connection(call_id, opts) do
          api_key = opts[:api_key] || System.get_env("MY_STT_KEY")
          url = "wss://api.provider.com/v1/listen?sample_rate=8000"
          headers = [{"Authorization", "Bearer \#{api_key}"}]
          {:ok, url, headers, %{}}
        end

        @impl EVoiceKit.Providers.STT
        def parse_speech_event({:text, json_str}, state) do
          case Jason.decode(json_str) do
            # Can return canonical atom :speech_started OR vendor string "vad_started"
            {:ok, %{"event" => "vad_started"}} ->
              {:speech_started, state}

            {:ok, %{"event" => "transcript", "text" => text, "final" => is_final}} ->
              {:transcript, text, is_final, is_final, state}

            _ ->
              :ignore
          end
        end
      end
  """

  # ----------------------------------------------------------------------------
  # Core Behaviour Callbacks
  # ----------------------------------------------------------------------------

  @doc """
  Starts the streaming STT connection for an active call session.
  Must return `{:ok, pid}` or `{:error, reason}`.
  """
  @callback start_link(session_pid :: pid(), call_id :: binary(), opts :: keyword()) ::
              {:ok, pid()} | {:error, term()}

  @doc """
  Streams an incoming chunk of telephony G.711 μ-law audio to the provider.
  """
  @callback send_audio(pid :: pid(), mulaw_chunk :: binary()) :: :ok | {:error, term()}

  @doc """
  Gracefully closes the speech stream.
  """
  @callback close(pid :: pid()) :: :ok

  # ----------------------------------------------------------------------------
  # Base Class Macro Callbacks (when using `use EVoiceKit.Providers.STT`)
  # ----------------------------------------------------------------------------

  @callback build_connection(call_id :: binary(), opts :: keyword()) ::
              {:ok, url :: binary(), headers :: list(), provider_state :: term()}
              | {:error, term()}

  @callback parse_speech_event(raw_frame :: {:text, binary()} | {:binary, binary()}, state :: term()) ::
              {:speech_started, new_state :: term()}
              | {:speech_ended, new_state :: term()}
              | {:transcript, text :: binary(), is_final :: boolean(), speech_final :: boolean(), new_state :: term()}
              | {:transcript, text :: binary(), is_final :: boolean(), new_state :: term()}
              | {vendor_event :: binary() | atom(), new_state :: term()}
              | {:reply, frame :: term(), new_state :: term()}
              | {:ok, new_state :: term()}
              | :ignore
              | {:error, term()}

  @callback encode_close_frame(state :: term()) ::
              {:ok, frame :: term()}
              | :ignore

  # Optional callbacks with defaults
  @optional_callbacks [
    build_connection: 2,
    parse_speech_event: 2,
    encode_close_frame: 1
  ]

  # ----------------------------------------------------------------------------
  # Abstract Base Class Macro
  # ----------------------------------------------------------------------------

  defmacro __using__(opts) do
    audio_format = Keyword.get(opts, :audio_format, :mulaw)

    quote do
      @behaviour EVoiceKit.Providers.STT
      use WebSockex
      require Logger
      alias EVoiceKit.Codec.G711
      alias EVoiceKit.Providers.Events

      defstruct session_pid: nil,
                call_id: nil,
                provider_state: %{}

      # ------------------------------------------------------------------------
      # Public Provider API
      # ------------------------------------------------------------------------

      @impl EVoiceKit.Providers.STT
      def start_link(session_pid, call_id, opts \\ []) do
        case build_connection(call_id, opts) do
          {:ok, url, headers, provider_state} ->
            state = %__MODULE__{
              session_pid: session_pid,
              call_id: call_id,
              provider_state: provider_state
            }

            WebSockex.start_link(url, __MODULE__, state, extra_headers: headers)

          {:error, reason} ->
            Logger.error("[STT:\#{call_id}] Failed to build connection: \#{inspect(reason)}")
            {:error, reason}
        end
      end

      @impl EVoiceKit.Providers.STT
      def send_audio(pid, mulaw_chunk) when is_binary(mulaw_chunk) do
        unquote(
          if audio_format == :pcm_16 do
            quote do
              # Transcode 8kHz G.711 μ-law to 16-bit signed linear PCM
              pcm_audio = G711.decode_mulaw(mulaw_chunk)
              WebSockex.send_frame(pid, {:binary, pcm_audio})
            end
          else
            quote do
              # Transmit raw μ-law directly
              WebSockex.send_frame(pid, {:binary, mulaw_chunk})
            end
          end
        )
      end

      @impl EVoiceKit.Providers.STT
      def close(pid) do
        WebSockex.cast(pid, :close_stream)
      end

      # ------------------------------------------------------------------------
      # WebSockex Callbacks
      # ------------------------------------------------------------------------

      @impl WebSockex
      def handle_connect(_conn, state) do
        Logger.info("[STT:\#{state.call_id}] Connected to \#{inspect(__MODULE__)}")
        handle_connected(state)
        {:ok, state}
      end

      @impl WebSockex
      def handle_cast(:close_stream, state) do
        case encode_close_frame(state) do
          {:ok, frame} ->
            {:reply, frame, state}

          :ignore ->
            {:ok, state}
        end
      end

      @impl WebSockex
      def handle_frame(frame, state) do
        case parse_speech_event(frame, state) do
          # 1. Canonical Speech Started (VAD onset / barge-in)
          {:speech_started, new_state} ->
            Logger.debug("[STT:\#{state.call_id}] Canonical :speech_started received (barge-in)")
            send(state.session_pid, {:stt_speech_started, state.call_id})
            {:ok, new_state}

          # 2. Canonical Speech Ended (VAD silence endpointing)
          {:speech_ended, new_state} ->
            Logger.debug("[STT:\#{state.call_id}] Canonical :speech_ended received")
            send(state.session_pid, {:stt_speech_ended, state.call_id})
            {:ok, new_state}

          # 3. Canonical Utterance Transcript
          {:transcript, text, is_final, speech_final, new_state} ->
            send(state.session_pid, {:stt_transcript, state.call_id, text, is_final, speech_final})
            {:ok, new_state}

          {:transcript, text, is_final, new_state} ->
            send(state.session_pid, {:stt_transcript, state.call_id, text, is_final, is_final})
            {:ok, new_state}

          # 4. Automatic Vendor-to-Canonical Event Resolution (e.g. "vad_started", "SpeechStarted")
          {vendor_event, new_state} when is_binary(vendor_event) or is_atom(vendor_event) ->
            case Events.normalize_stt_event(vendor_event) do
              :speech_started ->
                Logger.debug("[STT:\#{state.call_id}] Normalized '\#{vendor_event}' -> :speech_started (barge-in)")
                send(state.session_pid, {:stt_speech_started, state.call_id})
                {:ok, new_state}

              :speech_ended ->
                Logger.debug("[STT:\#{state.call_id}] Normalized '\#{vendor_event}' -> :speech_ended")
                send(state.session_pid, {:stt_speech_ended, state.call_id})
                {:ok, new_state}

              :ignore ->
                {:ok, new_state}
            end

          {:reply, frame, new_state} ->
            {:reply, frame, new_state}

          {:ok, new_state} ->
            {:ok, new_state}

          :ignore ->
            {:ok, state}

          {:error, reason} ->
            Logger.warning("[STT:\#{state.call_id}] Error parsing speech event: \#{inspect(reason)}")
            {:ok, state}
        end
      end

      @impl WebSockex
      def handle_disconnect(disconnect_map, state) do
        Logger.warning("[STT:\#{state.call_id}] Disconnected from STT: \#{inspect(disconnect_map)}")
        handle_disconnected(disconnect_map, state)
        {:ok, state}
      end

      # ------------------------------------------------------------------------
      # Overridable Defaults
      # ------------------------------------------------------------------------

      def handle_connected(state), do: :ok
      def handle_disconnected(_disconnect_map, state), do: :ok
      def encode_close_frame(_state), do: :ignore

      defoverridable handle_connected: 1,
                     handle_disconnected: 2,
                     encode_close_frame: 1
    end
  end
end
