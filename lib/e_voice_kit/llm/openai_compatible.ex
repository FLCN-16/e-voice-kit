defmodule EVoiceKit.LLM.OpenAICompatible do
  @moduledoc """
  Streaming LLM client for OpenAI-compatible APIs using high-performance HTTP/2 SSE via Finch.

  Supports:
  - Groq (Ultra-low latency ~150ms TTFT)
  - Cerebras (High-speed Llama inference)
  - OpenAI (GPT-4o, GPT-4o-mini)
  - DeepSeek (deepseek-chat, deepseek-coder)
  - Ollama & vLLM (Local self-hosted models)
  """

  @behaviour EVoiceKit.LLM.Provider
  require Logger

  @default_endpoints %{
    groq: "https://api.groq.com/openai/v1/chat/completions",
    cerebras: "https://api.cerebras.ai/v1/chat/completions",
    openai: "https://api.openai.com/v1/chat/completions",
    deepseek: "https://api.deepseek.com/chat/completions",
    ollama: "http://localhost:11434/v1/chat/completions"
  }

  @impl true
  def stream_chat(messages, tools, opts, callback_fn) do
    provider = Keyword.get(opts, :provider, :groq)
    endpoint = Keyword.get(opts, :endpoint) || Map.get(@default_endpoints, provider, @default_endpoints.groq)
    api_key = Keyword.get(opts, :api_key) || resolve_api_key(provider)
    model = Keyword.get(opts, :model) || resolve_default_model(provider)
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 512)

    headers = [
      {"content-type", "application/json"}
    ]

    headers =
      if api_key && api_key != "" do
        [{"authorization", "Bearer #{api_key}"} | headers]
      else
        headers
      end

    body_map = %{
      model: model,
      messages: sanitize_messages(messages),
      temperature: temperature,
      max_tokens: max_tokens,
      stream: true
    }

    body_map =
      if is_list(tools) and tools != [] do
        Map.put(body_map, :tools, tools)
      else
        body_map
      end

    body = Jason.encode!(body_map)
    request = Finch.build(:post, endpoint, headers, body)

    initial_acc = %{
      buffer: "",
      callback: callback_fn
    }

    # Stream through Finch connection pool
    case Finch.stream(request, EVoiceKit.Finch, initial_acc, &handle_finch_stream/2, receive_timeout: 15_000) do
      {:ok, _final_acc} ->
        :ok

      {:error, reason} ->
        Logger.error("[OpenAICompatible:#{provider}] Finch stream error: #{inspect(reason)}")
        callback_fn.({:error, reason})
        {:error, reason}
    end
  end

  # Finch stream handler
  defp handle_finch_stream({:status, status}, acc) do
    if status >= 400 do
      Logger.error("[OpenAICompatible] Received HTTP error status: #{status}")
    end
    acc
  end

  defp handle_finch_stream({:headers, _headers}, acc), do: acc

  defp handle_finch_stream({:data, chunk}, %{buffer: buffer, callback: callback} = acc) do
    combined = buffer <> chunk
    lines = String.split(combined, "\n")

    # The last element might be an incomplete line
    {complete_lines, [incomplete]} = Enum.split(lines, -1)

    for line <- complete_lines do
      trimmed = String.trim(line)
      process_sse_line(trimmed, callback)
    end

    %{acc | buffer: incomplete}
  end

  defp process_sse_line("", _callback), do: :ok
  defp process_sse_line(":" <> _comment, _callback), do: :ok

  defp process_sse_line("data: [DONE]", callback) do
    callback.({:finish, "stop"})
  end

  defp process_sse_line("data: " <> payload, callback) do
    case Jason.decode(payload) do
      {:ok, %{"choices" => [choice | _]}} ->
        # 1. Content delta (speech tokens)
        case get_in(choice, ["delta", "content"]) do
          content when is_binary(content) and content != "" ->
            callback.({:token, content})

          _ ->
            :ok
        end

        # 2. Tool calls delta
        case get_in(choice, ["delta", "tool_calls"]) do
          tool_calls when is_list(tool_calls) ->
            for tc <- tool_calls do
              id = tc["id"]
              index = tc["index"]
              fn_map = tc["function"] || %{}
              name = fn_map["name"]
              args = fn_map["arguments"]

              call_id = id || "call_#{index}"

              if is_binary(name) and name != "" do
                callback.({:tool_call_start, call_id, name})
              end

              if is_binary(args) and args != "" do
                callback.({:tool_call_delta, call_id, args})
              end
            end

          _ ->
            :ok
        end

        # 3. Finish reason
        case choice["finish_reason"] do
          reason when is_binary(reason) ->
            callback.({:finish, reason})

          _ ->
            :ok
        end

      {:ok, other} ->
        Logger.debug("[OpenAICompatible] Unhandled SSE payload: #{inspect(other)}")
        :ok

      {:error, err} ->
        Logger.debug("[OpenAICompatible] JSON decode error on SSE line: #{inspect(err)}")
        :ok
    end
  end

  defp process_sse_line(_other, _callback), do: :ok

  defp resolve_api_key(:groq), do: Application.get_env(:e_voice_kit, :groq_api_key)
  defp resolve_api_key(:cerebras), do: Application.get_env(:e_voice_kit, :cerebras_api_key)
  defp resolve_api_key(:openai), do: Application.get_env(:e_voice_kit, :openai_api_key)
  defp resolve_api_key(:deepseek), do: Application.get_env(:e_voice_kit, :deepseek_api_key)
  defp resolve_api_key(:ollama), do: nil
  defp resolve_api_key(_), do: nil

  defp resolve_default_model(:groq), do: Application.get_env(:e_voice_kit, :groq_model, "llama-3.3-70b-versatile")
  defp resolve_default_model(:cerebras), do: Application.get_env(:e_voice_kit, :cerebras_model, "llama3.1-8b")
  defp resolve_default_model(:openai), do: Application.get_env(:e_voice_kit, :openai_model, "gpt-4o-mini")
  defp resolve_default_model(:deepseek), do: Application.get_env(:e_voice_kit, :deepseek_model, "deepseek-chat")
  defp resolve_default_model(:ollama), do: Application.get_env(:e_voice_kit, :ollama_model, "llama3.1")
  defp resolve_default_model(_), do: "gpt-4o-mini"

  defp sanitize_messages(messages) do
    Enum.map(messages, fn msg ->
      %{
        role: to_string(msg[:role] || msg["role"]),
        content: msg[:content] || msg["content"] || ""
      }
      |> maybe_put_name(msg)
      |> maybe_put_tool_call_id(msg)
      |> maybe_put_tool_calls(msg)
    end)
  end

  defp maybe_put_name(acc, msg) do
    case msg[:name] || msg["name"] do
      nil -> acc
      name -> Map.put(acc, :name, name)
    end
  end

  defp maybe_put_tool_call_id(acc, msg) do
    case msg[:tool_call_id] || msg["tool_call_id"] do
      nil -> acc
      id -> Map.put(acc, :tool_call_id, id)
    end
  end

  defp maybe_put_tool_calls(acc, msg) do
    case msg[:tool_calls] || msg["tool_calls"] do
      nil -> acc
      tcs -> Map.put(acc, :tool_calls, tcs)
    end
  end
end
