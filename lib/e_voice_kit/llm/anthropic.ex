defmodule EVoiceKit.LLM.Anthropic do
  @moduledoc """
  Streaming LLM client for Anthropic Claude (Claude 3.5 Sonnet / Claude 3.5 Haiku)
  using HTTP/2 SSE streaming via Finch.
  """

  @behaviour EVoiceKit.LLM.Provider
  require Logger

  @default_endpoint "https://api.anthropic.com/v1/messages"
  @default_model "claude-3-5-haiku-20241022"

  @impl true
  def stream_chat(messages, tools, opts, callback_fn) do
    endpoint = Keyword.get(opts, :endpoint, @default_endpoint)
    api_key = Keyword.get(opts, :api_key) || Application.get_env(:e_voice_kit, :anthropic_api_key)
    model = Keyword.get(opts, :model, @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, 512)
    temperature = Keyword.get(opts, :temperature, 0.7)

    {system_prompt, user_assistant_messages} = extract_system_prompt(messages)

    headers = [
      {"content-type", "application/json"},
      {"x-api-key", api_key || ""},
      {"anthropic-version", "2023-06-01"}
    ]

    body_map = %{
      model: model,
      max_tokens: max_tokens,
      temperature: temperature,
      messages: user_assistant_messages,
      stream: true
    }

    body_map =
      if system_prompt && system_prompt != "" do
        Map.put(body_map, :system, system_prompt)
      else
        body_map
      end

    body_map =
      if is_list(tools) and tools != [] do
        Map.put(body_map, :tools, format_anthropic_tools(tools))
      else
        body_map
      end

    body = Jason.encode!(body_map)
    request = Finch.build(:post, endpoint, headers, body)

    initial_acc = %{
      buffer: "",
      callback: callback_fn
    }

    case Finch.stream(request, EVoiceKit.Finch, initial_acc, &handle_finch_stream/2, receive_timeout: 15_000) do
      {:ok, _final_acc} ->
        :ok

      {:error, reason} ->
        Logger.error("[Anthropic] Finch stream error: #{inspect(reason)}")
        callback_fn.({:error, reason})
        {:error, reason}
    end
  end

  defp handle_finch_stream({:status, status}, acc) do
    if status >= 400 do
      Logger.error("[Anthropic] Received HTTP error status: #{status}")
    end
    acc
  end

  defp handle_finch_stream({:headers, _headers}, acc), do: acc

  defp handle_finch_stream({:data, chunk}, %{buffer: buffer, callback: callback} = acc) do
    combined = buffer <> chunk
    lines = String.split(combined, "\n")
    {complete_lines, [incomplete]} = Enum.split(lines, -1)

    for line <- complete_lines do
      trimmed = String.trim(line)
      process_sse_line(trimmed, callback)
    end

    %{acc | buffer: incomplete}
  end

  defp process_sse_line("", _callback), do: :ok
  defp process_sse_line("event: " <> _event_type, _callback), do: :ok

  defp process_sse_line("data: " <> payload, callback) do
    case Jason.decode(payload) do
      {:ok, %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}}} ->
        if is_binary(text) and text != "" do
          callback.({:token, text})
        end

      {:ok, %{"type" => "message_delta", "delta" => %{"stop_reason" => stop_reason}}} ->
        if is_binary(stop_reason) do
          callback.({:finish, stop_reason})
        end

      {:ok, %{"type" => "message_stop"}} ->
        callback.({:finish, "stop"})

      {:ok, _other} ->
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp process_sse_line(_other, _callback), do: :ok

  defp extract_system_prompt(messages) do
    system_msg =
      Enum.find(messages, fn msg ->
        role = msg[:role] || msg["role"]
        to_string(role) == "system"
      end)

    system_text =
      case system_msg do
        nil -> ""
        msg -> msg[:content] || msg["content"] || ""
      end

    remaining_msgs =
      messages
      |> Enum.reject(fn msg -> to_string(msg[:role] || msg["role"]) == "system" end)
      |> Enum.map(fn msg ->
        %{
          role: to_string(msg[:role] || msg["role"]),
          content: msg[:content] || msg["content"] || ""
        }
      end)

    {system_text, remaining_msgs}
  end

  defp format_anthropic_tools(tools) do
    Enum.map(tools, fn
      %{"type" => "function", "function" => func} ->
        %{
          name: func["name"],
          description: func["description"],
          input_schema: func["parameters"]
        }

      %{type: "function", function: func} ->
        %{
          name: func[:name] || func["name"],
          description: func[:description] || func["description"],
          input_schema: func[:parameters] || func["parameters"]
        }

      other ->
        other
    end)
  end
end
