defmodule VoiceGateway.LLM.Agent do
  @moduledoc """
  Pure Elixir Conversational LLM Agent.

  Manages conversational history, streaming LLM execution, sentence chunking for TTS,
  instant conversational fillers (< 500ms), and concurrent tool execution.
  """

  use GenServer
  require Logger

  alias VoiceGateway.LLM.{OpenAICompatible, Anthropic, SentenceChunker, Tools}

  defstruct session_pid: nil,
            call_id: nil,
            provider: :groq,
            model: nil,
            system_prompt: nil,
            messages: [],
            tools: [],
            chunker: nil,
            filler_timer: nil,
            streaming_task: nil,
            stream_active: false,
            tokens_emitted: 0,
            current_assistant_text: "",
            pending_tool_calls: %{},
            config: []

  @default_fillers [
    "Sure, let me check that for you.",
    "One moment please, looking that up.",
    "Got it, give me just a second.",
    "Understood, checking that right now."
  ]

  # ----------------------------------------------------------------------------
  # Client API
  # ----------------------------------------------------------------------------

  @doc """
  Starts a conversational agent GenServer for an active call.
  """
  def start_link(session_pid, call_id, opts \\ []) do
    GenServer.start_link(__MODULE__, {session_pid, call_id, opts})
  end

  @doc """
  Feeds a completed user turn transcript to the agent.
  """
  def user_turn(pid, transcript) when is_binary(transcript) do
    GenServer.cast(pid, {:user_turn, transcript})
  end

  @doc """
  Instantly aborts in-flight LLM generation and tool execution (caller barge-in).
  """
  def abort(pid) do
    GenServer.cast(pid, :abort)
  end

  @doc """
  Dynamically reconfigures LLM provider, model, or system prompt mid-call.
  """
  def update_config(pid, new_opts) when is_list(new_opts) do
    GenServer.call(pid, {:update_config, new_opts})
  end

  # ----------------------------------------------------------------------------
  # GenServer Callbacks
  # ----------------------------------------------------------------------------

  @impl true
  def init({session_pid, call_id, opts}) do
    provider =
      Keyword.get(opts, :llm_provider) ||
        Application.get_env(:voice_gateway, :default_llm_provider, :groq)

    model =
      Keyword.get(opts, :llm_model) ||
        Application.get_env(:voice_gateway, :default_llm_model)

    system_prompt =
      Keyword.get(opts, :system_prompt) ||
        Application.get_env(
          :voice_gateway,
          :default_system_prompt,
          "You are a helpful, concise AI phone assistant. Keep answers to 1-2 spoken sentences."
        )

    initial_messages = [
      %{role: "system", content: system_prompt}
    ]

    tools = Keyword.get(opts, :tools, Tools.default_tools())

    state = %__MODULE__{
      session_pid: session_pid,
      call_id: call_id,
      provider: provider,
      model: model,
      system_prompt: system_prompt,
      messages: initial_messages,
      tools: tools,
      chunker: SentenceChunker.new(),
      config: opts
    }

    Logger.info("[Agent:#{call_id}] Initialized with provider: #{provider}, model: #{model || "default"}")

    {:ok, state}
  end

  @impl true
  def handle_cast({:user_turn, transcript}, state) do
    trimmed = String.trim(transcript)

    if trimmed == "" do
      {:noreply, state}
    else
      # If previous generation was running, abort it
      state = terminate_active_stream(state)

      new_messages = state.messages ++ [%{role: "user", content: trimmed}]

      # Schedule 450ms conversational filler in case LLM TTFT is delayed
      filler_timer = Process.send_after(self(), :emit_filler, 450)

      state = %{
        state
        | messages: new_messages,
          stream_active: true,
          tokens_emitted: 0,
          current_assistant_text: "",
          pending_tool_calls: %{},
          chunker: SentenceChunker.reset(state.chunker),
          filler_timer: filler_timer
      }

      state = start_llm_stream(state)
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:abort, state) do
    Logger.info("[Agent:#{state.call_id}] Aborting in-flight LLM generation (barge-in)")
    state = terminate_active_stream(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:update_config, new_opts}, _from, state) do
    provider = Keyword.get(new_opts, :llm_provider, state.provider)
    model = Keyword.get(new_opts, :llm_model, state.model)
    system_prompt = Keyword.get(new_opts, :system_prompt, state.system_prompt)

    messages =
      if system_prompt != state.system_prompt do
        [%{role: "system", content: system_prompt} | Enum.reject(state.messages, &(&1[:role] == "system"))]
      else
        state.messages
      end

    new_state = %{
      state
      | provider: provider,
        model: model,
        system_prompt: system_prompt,
        messages: messages,
        config: Keyword.merge(state.config, new_opts)
    }

    Logger.info("[Agent:#{state.call_id}] Reconfigured to provider: #{provider}, model: #{model}")
    {:reply, :ok, new_state}
  end

  # ----------------------------------------------------------------------------
  # Streaming & Timer Handlers
  # ----------------------------------------------------------------------------

  @impl true
  def handle_info(:emit_filler, %{stream_active: true, tokens_emitted: 0} = state) do
    filler = Enum.random(@default_fillers)
    Logger.debug("[Agent:#{state.call_id}] Emitting filler phrase: #{filler}")
    send(state.session_pid, {:brain_filler, filler})
    {:noreply, %{state | filler_timer: nil}}
  end

  def handle_info(:emit_filler, state), do: {:noreply, %{state | filler_timer: nil}}

  # Internal token emitted by streaming task
  @impl true
  def handle_info({:stream_token, token}, %{stream_active: true} = state) do
    # Cancel filler timer as soon as first token arrives
    if state.filler_timer, do: Process.cancel_timer(state.filler_timer)

    {chunks, new_chunker} = SentenceChunker.push(state.chunker, token)

    for chunk <- chunks do
      send(state.session_pid, {:brain_token, chunk})
    end

    {:noreply,
     %{
       state
       | chunker: new_chunker,
         filler_timer: nil,
         tokens_emitted: state.tokens_emitted + 1,
         current_assistant_text: state.current_assistant_text <> token
     }}
  end

  def handle_info({:stream_token, _token}, state), do: {:noreply, state}

  # Tool call start
  @impl true
  def handle_info({:stream_tool_start, id, name}, %{stream_active: true} = state) do
    tool_entry = %{id: id, name: name, arguments: ""}
    new_pending = Map.put(state.pending_tool_calls, id, tool_entry)
    {:noreply, %{state | pending_tool_calls: new_pending}}
  end

  def handle_info({:stream_tool_start, _id, _name}, state), do: {:noreply, state}

  # Tool call arguments delta
  @impl true
  def handle_info({:stream_tool_delta, id, args_chunk}, %{stream_active: true} = state) do
    new_pending =
      Map.update(state.pending_tool_calls, id, %{id: id, name: "unknown", arguments: args_chunk}, fn entry ->
        %{entry | arguments: entry.arguments <> args_chunk}
      end)

    {:noreply, %{state | pending_tool_calls: new_pending}}
  end

  def handle_info({:stream_tool_delta, _id, _args}, state), do: {:noreply, state}

  # Stream finish
  @impl true
  def handle_info({:stream_finish, finish_reason}, %{stream_active: true} = state) do
    if state.filler_timer, do: Process.cancel_timer(state.filler_timer)

    # 1. Flush any trailing characters from SentenceChunker
    {final_chunks, _} = SentenceChunker.flush(state.chunker)

    for chunk <- final_chunks do
      send(state.session_pid, {:brain_token, chunk})
    end

    tool_calls_list = Map.values(state.pending_tool_calls)

    if tool_calls_list != [] or finish_reason in ["tool_calls", "function_call"] do
      # 2. Model requested tool calls
      handle_tool_execution(tool_calls_list, state)
    else
      # 3. Pure conversational turn finished
      assistant_msg = %{role: "assistant", content: state.current_assistant_text}
      new_messages = state.messages ++ [assistant_msg]

      send(state.session_pid, {:brain_turn_complete})

      {:noreply,
       %{
         state
         | messages: new_messages,
           stream_active: false,
           streaming_task: nil,
           filler_timer: nil,
           current_assistant_text: "",
           pending_tool_calls: %{}
       }}
    end
  end

  def handle_info({:stream_finish, _reason}, state), do: {:noreply, state}

  # Handle task exit
  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | streaming_task: nil}}
  end

  # Fallback for unexpected messages
  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  # ----------------------------------------------------------------------------
  # Internal Helpers
  # ----------------------------------------------------------------------------

  defp start_llm_stream(state) do
    parent_pid = self()
    provider = state.provider
    messages = state.messages
    tools = state.tools

    opts = [
      provider: provider,
      model: state.model
    ]

    callback_fn = fn
      {:token, text} ->
        send(parent_pid, {:stream_token, text})

      {:tool_call_start, id, name} ->
        send(parent_pid, {:stream_tool_start, id, name})

      {:tool_call_delta, id, args} ->
        send(parent_pid, {:stream_tool_delta, id, args})

      {:finish, reason} ->
        send(parent_pid, {:stream_finish, reason})

      {:error, reason} ->
        Logger.error("[Agent:#{state.call_id}] LLM error: #{inspect(reason)}")
        send(parent_pid, {:stream_finish, "error"})
    end

    task =
      Task.Supervisor.async_nolink(VoiceGateway.TaskSupervisor, fn ->
        case provider do
          :anthropic ->
            Anthropic.stream_chat(messages, tools, opts, callback_fn)

          _openai_compatible ->
            OpenAICompatible.stream_chat(messages, tools, opts, callback_fn)
        end
      end)

    %{state | streaming_task: task}
  end

  defp handle_tool_execution(tool_calls, state) do
    Logger.info("[Agent:#{state.call_id}] Executing #{length(tool_calls)} tool calls")

    # Send filler while tools execute
    send(state.session_pid, {:brain_filler, "Checking that right now for you."})

    # Execute tools concurrently
    results = Tools.execute_tools(tool_calls, %{call_id: state.call_id, config: state.config})

    # Emit any actions (e.g. transfer, hangup)
    for %{action: action} <- results, action != nil do
      {:action, action_type, payload} = action
      send(state.session_pid, {:brain_action, action_type, payload})
    end

    # Format assistant tool_calls message
    formatted_tcs =
      Enum.map(tool_calls, fn tc ->
        %{
          id: tc.id,
          type: "function",
          function: %{
            name: tc.name,
            arguments: tc.arguments
          }
        }
      end)

    assistant_msg = %{
      role: "assistant",
      content: state.current_assistant_text,
      tool_calls: formatted_tcs
    }

    tool_result_msgs =
      Enum.map(results, fn res ->
        %{
          role: "tool",
          tool_call_id: res.tool_call_id,
          content: res.result
        }
      end)

    new_messages = state.messages ++ [assistant_msg] ++ tool_result_msgs

    # Trigger second LLM turn to verbalize tool results to caller
    updated_state = %{
      state
      | messages: new_messages,
        pending_tool_calls: %{},
        tokens_emitted: 0,
        current_assistant_text: "",
        chunker: SentenceChunker.reset(state.chunker)
    }

    start_llm_stream(updated_state)
    {:noreply, updated_state}
  end

  defp terminate_active_stream(state) do
    if state.filler_timer, do: Process.cancel_timer(state.filler_timer)

    if state.streaming_task do
      Task.shutdown(state.streaming_task, :brutal_kill)
    end

    %{
      state
      | stream_active: false,
        streaming_task: nil,
        filler_timer: nil,
        chunker: SentenceChunker.reset(state.chunker),
        pending_tool_calls: %{},
        current_assistant_text: ""
    }
  end
end
