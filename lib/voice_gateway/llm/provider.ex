defmodule VoiceGateway.LLM.Provider do
  @moduledoc """
  Pluggable behaviour for streaming LLM inference providers.

  Any LLM provider (OpenAI, Groq, Cerebras, Anthropic, Ollama, DeepSeek)
  implements this behaviour to stream token deltas and tool calls directly into
  the voice conversational pipeline.
  """

  @type message :: %{
          role: String.t(),
          content: String.t() | list() | nil,
          name: String.t() | nil,
          tool_call_id: String.t() | nil,
          tool_calls: list() | nil
        }

  @type tool_def :: %{
          type: String.t(),
          function: %{
            name: String.t(),
            description: String.t(),
            parameters: map()
          }
        }

  @type stream_event ::
          {:token, String.t()}
          | {:tool_call_start, id :: String.t(), name :: String.t()}
          | {:tool_call_delta, id :: String.t(), argument_chunk :: String.t()}
          | {:tool_call_done, id :: String.t()}
          | {:finish, reason :: String.t() | nil}
          | {:error, term()}

  @doc """
  Initiates a streaming chat completion request and invokes callback_fn for each event.
  """
  @callback stream_chat(
              messages :: [message()],
              tools :: [tool_def()],
              opts :: keyword(),
              callback_fn :: (stream_event() -> any())
            ) :: :ok | {:error, term()}
end
