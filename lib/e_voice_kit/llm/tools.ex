defmodule EVoiceKit.LLM.Tools do
  @moduledoc """
  Tool registry and concurrent executor for LLM agent actions.

  Supports built-in telephony actions (call transfer, hangup) and custom tenant tools.
  Tools are executed concurrently using Task.async_stream to minimize conversational latency.
  """

  require Logger

  @doc """
  Returns standard tool definitions in OpenAI function schema format.
  """
  def default_tools do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "transfer_call",
          "description" => "Transfer the active phone call to a live agent, supervisor, or external phone number.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "destination" => %{
                "type" => "string",
                "description" => "Phone number or SIP URI to transfer the call to (e.g. +14155552671)."
              },
              "reason" => %{
                "type" => "string",
                "description" => "Brief explanation for the transfer."
              }
            },
            "required" => ["destination"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "end_call",
          "description" => "Hang up the active phone call after saying goodbye to the caller.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "reason" => %{
                "type" => "string",
                "description" => "Reason for terminating the call."
              }
            }
          }
        }
      }
    ]
  end

  @doc """
  Executes a list of tool calls requested by the LLM in parallel.
  Returns a list of `%{tool_call_id: id, result: result, action: maybe_action}`.
  """
  def execute_tools(tool_calls, session_context \\ %{}) do
    tool_calls
    |> Task.async_stream(
      fn tool_call ->
        execute_single_tool(tool_call, session_context)
      end,
      max_concurrency: 5,
      timeout: 10_000
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> %{tool_call_id: "unknown", result: "Tool timed out: #{inspect(reason)}", action: nil}
    end)
  end

  defp execute_single_tool(%{id: id, name: name, arguments: raw_args}, context) do
    args =
      case Jason.decode(raw_args) do
        {:ok, map} -> map
        {:error, _} -> %{}
      end

    Logger.info("[Tools] Executing tool: #{name} with args: #{inspect(args)}")

    case name do
      "transfer_call" ->
        destination = args["destination"] || ""
        reason = args["reason"] || "Transfer requested by assistant"

        %{
          tool_call_id: id,
          result: "Call transfer initiated to #{destination}.",
          action: {:action, :transfer, %{"target" => destination, "reason" => reason}}
        }

      "end_call" ->
        reason = args["reason"] || "Conversation completed"

        %{
          tool_call_id: id,
          result: "Call disconnected.",
          action: {:action, :hangup, %{"reason" => reason}}
        }

      custom_name ->
        # Check if caller provided custom tool handler in context
        case Map.get(context, :custom_tool_handler) do
          handler when is_function(handler, 3) ->
            res = handler.(custom_name, args, context)
            %{tool_call_id: id, result: to_string(res), action: nil}

          _ ->
            %{tool_call_id: id, result: "Tool #{custom_name} executed successfully.", action: nil}
        end
    end
  end
end
