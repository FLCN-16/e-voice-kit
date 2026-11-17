defmodule VoiceGateway.LLM.SentenceChunker do
  @moduledoc """
  Real-time sentence and clause boundary chunker for streaming LLM responses.

  Accumulates streaming LLM token deltas and flushes spoken phrases at
  clause and sentence boundaries for optimal TTS naturalness and minimal TTFA (Time-To-First-Audio).
  """

  defstruct buffer: "",
            min_first_chunk_chars: 15,
            min_subsequent_chars: 30,
            first_chunk_sent: false

  @doc """
  Initializes a new SentenceChunker with configurable chunk lengths.
  """
  def new(opts \\ []) do
    %__MODULE__{
      buffer: "",
      min_first_chunk_chars: Keyword.get(opts, :min_first_chunk_chars, 15),
      min_subsequent_chars: Keyword.get(opts, :min_subsequent_chars, 30),
      first_chunk_sent: false
    }
  end

  @doc """
  Pushes a new token delta into the chunker.
  Returns `{chunks_to_emit, updated_chunker}`.
  """
  def push(%__MODULE__{} = chunker, token) when is_binary(token) do
    new_buf = chunker.buffer <> token
    min_len = if chunker.first_chunk_sent, do: chunker.min_subsequent_chars, do: chunker.min_first_chunk_chars

    case find_split_point(new_buf, min_len) do
      {:split, phrase, rest} ->
        chunker = %{chunker | buffer: rest, first_chunk_sent: true}
        {[String.trim(phrase)], chunker}

      :no_split ->
        {[], %{chunker | buffer: new_buf}}
    end
  end

  @doc """
  Flushes any remaining text in the buffer when the LLM stream terminates.
  Returns `{final_chunks, reset_chunker}`.
  """
  def flush(%__MODULE__{buffer: buffer} = chunker) do
    trimmed = String.trim(buffer)

    if trimmed != "" do
      {[trimmed], %{chunker | buffer: "", first_chunk_sent: false}}
    else
      {[], %{chunker | buffer: "", first_chunk_sent: false}}
    end
  end

  @doc """
  Resets the chunker buffer immediately (e.g. on barge-in).
  """
  def reset(%__MODULE__{} = chunker) do
    %{chunker | buffer: "", first_chunk_sent: false}
  end

  # Internal clause & sentence boundary detector
  defp find_split_point(text, min_len) do
    if String.length(text) < min_len do
      :no_split
    else
      # Check full stop boundaries (. ? ! \n)
      case Regex.run(~r/^(.*?[\.\?\!\n])\s+(.*)$/s, text) do
        [_, phrase, rest] when byte_size(phrase) >= min_len ->
          {:split, phrase, rest}

        _ ->
          # Check clause boundaries (, ; : —) if text length is sufficient
          if String.length(text) >= min_len * 1.3 do
            case Regex.run(~r/^(.*?[,;:\—\-])\s+(.*)$/s, text) do
              [_, phrase, rest] ->
                {:split, phrase, rest}

              _ ->
                :no_split
            end
          else
            :no_split
          end
      end
    end
  end
end
