defmodule EVoiceKit.Clients.STTStreamer do
  @moduledoc """
  Unified, pluggable STT client and provider dispatcher for real-time speech-to-text.

  Supports dynamic registration of any module implementing `EVoiceKit.Providers.STT`.
  Default built-in providers:
  - `:deepgram` -> `EVoiceKit.Clients.DeepgramSTT`
  - `:assemblyai` -> `EVoiceKit.Clients.AssemblyAISTT`
  - `:sarvam` -> `EVoiceKit.Clients.SarvamSTT`

  ## Registering Custom Providers

      config :e_voice_kit, :stt_providers, %{
        my_custom_stt: MyCompany.CustomSTT
      }
  """

  require Logger
  alias EVoiceKit.Clients.{DeepgramSTT, AssemblyAISTT, SarvamSTT, WhisperSTT}

  @default_providers %{
    deepgram: DeepgramSTT,
    assemblyai: AssemblyAISTT,
    sarvam: SarvamSTT,
    whisper: WhisperSTT
  }

  @type client_handle :: {module(), pid()} | pid()

  @doc """
  Returns the active map of registered STT providers.
  """
  def registered_providers do
    custom = Application.get_env(:e_voice_kit, :stt_providers, %{})
    Map.merge(@default_providers, custom)
  end

  @doc """
  Starts the configured STT provider client for an active call.
  Returns `{:ok, {client_module, pid}}`.
  """
  def start_link(session_pid, call_id, opts \\ []) do
    provider_key =
      opts[:stt_provider] ||
        opts[:provider] ||
        Application.get_env(:e_voice_kit, :default_stt_provider, :deepgram)

    provider_module = Map.get(registered_providers(), provider_key)

    if provider_module do
      with {:ok, pid} <- provider_module.start_link(session_pid, call_id, opts) do
        {:ok, {provider_module, pid}}
      end
    else
      Logger.warning("[STT:#{call_id}] Unknown provider #{inspect(provider_key)}, falling back to Deepgram")
      with {:ok, pid} <- DeepgramSTT.start_link(session_pid, call_id, opts) do
        {:ok, {DeepgramSTT, pid}}
      end
    end
  end

  @doc """
  Streams a chunk of telephony μ-law audio to the active STT client,
  ensuring any provider-specific transcoding (e.g. μ-law to 16-bit PCM for AssemblyAI/Sarvam)
  is properly executed.
  """
  @spec send_audio(client_handle(), binary()) :: :ok | {:error, term()}
  def send_audio({module, pid}, chunk) when is_binary(chunk) and is_pid(pid) do
    if Process.alive?(pid) do
      module.send_audio(pid, chunk)
    else
      {:error, :client_dead}
    end
  end

  def send_audio(pid, chunk) when is_pid(pid) and is_binary(chunk) do
    if Process.alive?(pid) do
      DeepgramSTT.send_audio(pid, chunk)
    else
      {:error, :client_dead}
    end
  end

  @doc """
  Closes the active STT client stream.
  """
  @spec close(client_handle()) :: :ok
  def close({module, pid}) when is_pid(pid) do
    if Process.alive?(pid), do: module.close(pid)
    :ok
  end

  def close(pid) when is_pid(pid) do
    if Process.alive?(pid), do: DeepgramSTT.close(pid)
    :ok
  end
end
