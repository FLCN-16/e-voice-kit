defmodule EVoiceKit.Clients.TTSStreamer do
  @moduledoc """
  Unified, pluggable TTS client and provider dispatcher for real-time speech synthesis.

  Supports dynamic registration of any module implementing `EVoiceKit.Providers.TTS`.
  Default built-in providers:
  - `:cartesia` -> `EVoiceKit.Clients.CartesiaTTS`
  - `:elevenlabs` -> `EVoiceKit.Clients.ElevenLabsTTS`
  - `:fishaudio` -> `EVoiceKit.Clients.FishAudioTTS`
  - `:sarvam` -> `EVoiceKit.Clients.SarvamTTS`

  ## Registering Custom Providers

      config :e_voice_kit, :tts_providers, %{
        my_custom_tts: MyCompany.CustomTTS
      }
  """

  require Logger
  alias EVoiceKit.Clients.{CartesiaTTS, ElevenLabsTTS, FishAudioTTS, SarvamTTS, OpenAITTS}

  @default_providers %{
    cartesia: CartesiaTTS,
    elevenlabs: ElevenLabsTTS,
    fishaudio: FishAudioTTS,
    fish_audio: FishAudioTTS,
    sarvam: SarvamTTS,
    openai: OpenAITTS
  }

  @type client_handle :: {module(), pid()} | pid()

  @doc """
  Returns the active map of registered TTS providers.
  """
  def registered_providers do
    custom = Application.get_env(:e_voice_kit, :tts_providers, %{})
    Map.merge(@default_providers, custom)
  end

  @doc """
  Starts the configured TTS provider client for an active call.
  Returns `{:ok, {client_module, pid}}`.
  """
  def start_link(session_pid, call_id, opts \\ []) do
    provider_key =
      opts[:tts_provider] ||
        opts[:provider] ||
        Application.get_env(:e_voice_kit, :default_tts_provider, :cartesia)

    provider_module = Map.get(registered_providers(), provider_key)

    if provider_module do
      with {:ok, pid} <- provider_module.start_link(session_pid, call_id, opts) do
        {:ok, {provider_module, pid}}
      end
    else
      Logger.warning("[TTS:#{call_id}] Unknown provider #{inspect(provider_key)}, falling back to Cartesia")
      with {:ok, pid} <- CartesiaTTS.start_link(session_pid, call_id, opts) do
        {:ok, {CartesiaTTS, pid}}
      end
    end
  end

  @doc """
  Streams a text token or phrase to the active TTS client.
  """
  @spec stream_text(client_handle(), binary(), boolean()) :: :ok
  def stream_text({module, pid}, text, continue? \\ true) when is_binary(text) and is_pid(pid) do
    if Process.alive?(pid) do
      module.stream_text(pid, text, continue?)
    else
      :ok
    end
  end

  def stream_text(pid, text, continue?) when is_pid(pid) and is_binary(text) do
    if Process.alive?(pid) do
      CartesiaTTS.stream_text(pid, text, continue?)
    else
      :ok
    end
  end

  @doc """
  Sends an instant abort signal to cancel in-flight TTS generation on caller barge-in.
  """
  @spec abort(client_handle()) :: :ok
  def abort({module, pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      module.abort(pid)
    else
      :ok
    end
  end

  def abort(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      CartesiaTTS.abort(pid)
    else
      :ok
    end
  end
end
