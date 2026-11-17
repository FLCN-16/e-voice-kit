defmodule EVoiceKit.Providers.TTS do
  @moduledoc """
  Pluggable behaviour and abstract base class macro for Text-to-Speech (TTS) providers.

  Any community or custom TTS provider can be created by adopting this behaviour or
  by writing `use EVoiceKit.Providers.TTS`, which manages WebSockex connections,
  text stream encoding, audio packet decoding (with automatic PCM-to-μ-law transcoding),
  canonical event normalization (`:turn_completed`, `:turn_aborted`), and barge-in
  abort commands automatically.

  ## Canonical Event Mapping
  Regardless of vendor naming (`"done"`, `"turn_completed"`, `"response.audio.done"`,
  or `"is_final"`), all events resolve to unified canonical enums via `EVoiceKit.Providers.Events`.

  ## Example Implementation

      defmodule EVoiceKit.Clients.MyCustomTTS do
        use EVoiceKit.Providers.TTS, audio_format: :mulaw

        @impl EVoiceKit.Providers.TTS
        def build_connection(call_id, opts) do
          api_key = opts[:api_key] || System.get_env("MY_TTS_KEY")
          url = "wss://api.provider.com/v1/synthesize"
          headers = [{"Authorization", "Bearer \#{api_key}"}]
          {:ok, url, headers, %{voice_id: opts[:voice_id] || "default"}}
        end

        @impl EVoiceKit.Providers.TTS
        def encode_text_frame(text, continue?, state) do
          payload = %{"text" => text, "continue" => continue?}
          {:reply, {:text, Jason.encode!(payload)}, state}
        end

        @impl EVoiceKit.Providers.TTS
        def parse_audio_event({:text, json_str}, state) do
          case Jason.decode(json_str) do
            {:ok, %{"audio" => b64}} ->
              {:audio, Base.decode64!(b64), state}

            # Return canonical :turn_completed OR vendor string like "done"
            {:ok, %{"event" => "done"}} ->
              {:turn_completed, state}

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
  Starts the streaming TTS connection for an active call session.
  Must return `{:ok, pid}` or `{:error, reason}`.
  """
  @callback start_link(session_pid :: pid(), call_id :: binary(), opts :: keyword()) ::
              {:ok, pid()} | {:error, term()}

  @doc """
  Streams a chunk of text to be synthesized into spoken telephony audio.
  """
  @callback stream_text(pid :: pid(), text :: binary(), continue? :: boolean()) :: :ok

  @doc """
  Immediately aborts in-flight audio synthesis (caller barge-in).
  """
  @callback abort(pid :: pid()) :: :ok

  # ----------------------------------------------------------------------------
  # Base Class Macro Callbacks (when using `use EVoiceKit.Providers.TTS`)
  # ----------------------------------------------------------------------------

  @callback build_connection(call_id :: binary(), opts :: keyword()) ::
              {:ok, url :: binary(), headers :: list(), provider_state :: term()}
              | {:error, term()}

  @callback encode_text_frame(text :: binary(), continue? :: boolean(), state :: term()) ::
              {:reply, frame :: term(), new_state :: term()}
              | {:ok, new_state :: term()}
              | :ignore

  @callback parse_audio_event(raw_frame :: {:text, binary()} | {:binary, binary()}, state :: term()) ::
              {:audio, audio_bytes :: binary(), new_state :: term()}
              | {:turn_completed, new_state :: term()}
              | {:turn_aborted, new_state :: term()}
              | {vendor_event :: binary() | atom(), new_state :: term()}
              | {:ok, new_state :: term()}
              | :ignore
              | {:error, term()}

  @callback encode_abort_frame(state :: term()) ::
              {:reply, frame :: term(), new_state :: term()}
              | {:ok, new_state :: term()}
              | :ignore

  @optional_callbacks [
    build_connection: 2,
    encode_text_frame: 3,
    parse_audio_event: 2,
    encode_abort_frame: 1
  ]

  # ----------------------------------------------------------------------------
  # Abstract Base Class Macro
  # ----------------------------------------------------------------------------

  defmacro __using__(opts) do
    audio_format = Keyword.get(opts, :audio_format, :mulaw)

    quote do
      @behaviour EVoiceKit.Providers.TTS
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

      @impl EVoiceKit.Providers.TTS
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
            Logger.error("[TTS:\#{call_id}] Failed to build connection: \#{inspect(reason)}")
            {:error, reason}
        end
      end

      @impl EVoiceKit.Providers.TTS
      def stream_text(pid, text, continue? \\ true) when is_binary(text) do
        WebSockex.cast(pid, {:stream_text, text, continue?})
      end

      @impl EVoiceKit.Providers.TTS
      def abort(pid) do
        WebSockex.cast(pid, :abort_synthesis)
      end

      # ------------------------------------------------------------------------
      # WebSockex Callbacks
      # ------------------------------------------------------------------------

      @impl WebSockex
      def handle_connect(_conn, state) do
        Logger.info("[TTS:\#{state.call_id}] Connected to \#{inspect(__MODULE__)}")
        handle_connected(state)
        {:ok, state}
      end

      @impl WebSockex
      def handle_cast({:stream_text, text, continue?}, state) do
        case encode_text_frame(text, continue?, state) do
          {:reply, frame, new_state} ->
            {:reply, frame, new_state}

          {:ok, new_state} ->
            {:ok, new_state}

          :ignore ->
            {:ok, state}
        end
      end

      @impl WebSockex
      def handle_cast(:abort_synthesis, state) do
        case encode_abort_frame(state) do
          {:reply, frame, new_state} ->
            {:reply, frame, new_state}

          {:ok, new_state} ->
            {:ok, new_state}

          :ignore ->
            {:ok, state}
        end
      end

      @impl WebSockex
      def handle_frame(frame, state) do
        case parse_audio_event(frame, state) do
          # 1. Audio payload chunk
          {:audio, raw_bytes, new_state} ->
            unquote(
              if audio_format == :pcm_16 do
                quote do
                  # Transcode 16-bit linear PCM audio to 8kHz G.711 μ-law
                  mulaw_chunk = G711.encode_mulaw(raw_bytes)
                  send(state.session_pid, {:tts_audio_chunk, mulaw_chunk})
                end
              else
                quote do
                  # Native μ-law telephony audio
                  send(state.session_pid, {:tts_audio_chunk, raw_bytes})
                end
              end
            )

            {:ok, new_state}

          # 2. Canonical Turn Completed
          {:turn_completed, new_state} ->
            send(state.session_pid, {:tts_turn_completed, state.call_id})
            {:ok, new_state}

          # 3. Canonical Turn Aborted
          {:turn_aborted, new_state} ->
            Logger.debug("[TTS:\#{state.call_id}] Turn playback aborted by provider")
            {:ok, new_state}

          # 4. Automatic Vendor-to-Canonical Event Resolution (e.g. "done", "response.audio.done")
          {vendor_event, new_state} when is_binary(vendor_event) or is_atom(vendor_event) ->
            case Events.normalize_tts_event(vendor_event) do
              :turn_completed ->
                send(state.session_pid, {:tts_turn_completed, state.call_id})
                {:ok, new_state}

              :turn_aborted ->
                Logger.debug("[TTS:\#{state.call_id}] Normalized '\#{vendor_event}' -> :turn_aborted")
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
            Logger.warning("[TTS:\#{state.call_id}] Error parsing audio event: \#{inspect(reason)}")
            {:ok, state}
        end
      end

      @impl WebSockex
      def handle_disconnect(disconnect_map, state) do
        Logger.warning("[TTS:\#{state.call_id}] Disconnected from TTS: \#{inspect(disconnect_map)}")
        handle_disconnected(disconnect_map, state)
        {:ok, state}
      end

      # ------------------------------------------------------------------------
      # Overridable Defaults
      # ------------------------------------------------------------------------

      def handle_connected(state), do: :ok
      def handle_disconnected(_disconnect_map, state), do: :ok
      def encode_abort_frame(state), do: {:ok, state}

      defoverridable handle_connected: 1,
                     handle_disconnected: 2,
                     encode_abort_frame: 1
    end
  end
end
