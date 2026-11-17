defmodule EVoiceKit.LLM.ToolsTest do
  use ExUnit.Case, async: true
  alias EVoiceKit.LLM.Tools

  describe "default_tools/0" do
    test "returns transfer_call and end_call schemas" do
      tools = Tools.default_tools()
      assert is_list(tools)
      assert length(tools) == 2

      names = Enum.map(tools, fn t -> get_in(t, ["function", "name"]) end)
      assert "transfer_call" in names
      assert "end_call" in names
    end
  end

  describe "execute_tools/2" do
    test "executes transfer_call tool and generates transfer action" do
      tool_calls = [
        %{
          id: "call_123",
          name: "transfer_call",
          arguments: Jason.encode!(%{"destination" => "+18005550199", "reason" => "billing inquiry"})
        }
      ]

      [result] = Tools.execute_tools(tool_calls)

      assert result.tool_call_id == "call_123"
      assert result.result =~ "Call transfer initiated"
      assert result.action == {:action, :transfer, %{"target" => "+18005550199", "reason" => "billing inquiry"}}
    end

    test "executes end_call tool and generates hangup action" do
      tool_calls = [
        %{
          id: "call_456",
          name: "end_call",
          arguments: Jason.encode!(%{"reason" => "caller satisfied"})
        }
      ]

      [result] = Tools.execute_tools(tool_calls)

      assert result.tool_call_id == "call_456"
      assert result.action == {:action, :hangup, %{"reason" => "caller satisfied"}}
    end

    test "executes custom tenant callback when provided in context" do
      custom_handler = fn "check_balance", args, _ctx ->
        "Balance for account #{args["account_id"]} is $150.00"
      end

      tool_calls = [
        %{
          id: "call_789",
          name: "check_balance",
          arguments: Jason.encode!(%{"account_id" => "ACT-999"})
        }
      ]

      [result] = Tools.execute_tools(tool_calls, %{custom_tool_handler: custom_handler})

      assert result.tool_call_id == "call_789"
      assert result.result == "Balance for account ACT-999 is $150.00"
      assert is_nil(result.action)
    end
  end
end
