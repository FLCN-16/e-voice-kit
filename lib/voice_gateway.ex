defmodule VoiceGateway do
  @moduledoc """
  Backward compatibility module for `EVoiceKit`.
  Please use `EVoiceKit` in new code.
  """

  defdelegate active_calls_count(), to: EVoiceKit
  defdelegate get_session(call_id), to: EVoiceKit
  defdelegate reconfigure_call(call_id, new_config), to: EVoiceKit
end
