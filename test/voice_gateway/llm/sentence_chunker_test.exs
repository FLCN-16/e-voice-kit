defmodule VoiceGateway.LLM.SentenceChunkerTest do
  use ExUnit.Case, async: true
  alias VoiceGateway.LLM.SentenceChunker

  describe "SentenceChunker" do
    test "initializes with default options" do
      chunker = SentenceChunker.new()
      assert chunker.buffer == ""
      assert chunker.first_chunk_sent == false
    end

    test "splits on sentence punctuation once minimum character length is met" do
      chunker = SentenceChunker.new(min_first_chunk_chars: 10)

      # Push tokens one by one
      {c1, chunker} = SentenceChunker.push(chunker, "Hello ")
      assert c1 == []

      {c2, chunker} = SentenceChunker.push(chunker, "world! ")
      assert c2 == ["Hello world!"]
      assert chunker.first_chunk_sent == true
      assert chunker.buffer == ""
    end

    test "retains remainder after split" do
      chunker = SentenceChunker.new(min_first_chunk_chars: 10)

      {chunks, chunker} = SentenceChunker.push(chunker, "Hello there! How are you doing today?")
      assert chunks == ["Hello there!"]
      assert chunker.buffer == "How are you doing today?"
    end

    test "flushes incomplete final buffer when stream finishes" do
      chunker = SentenceChunker.new()
      {_, chunker} = SentenceChunker.push(chunker, "I can help with that")

      {final_chunks, reset_chunker} = SentenceChunker.flush(chunker)
      assert final_chunks == ["I can help with that"]
      assert reset_chunker.buffer == ""
    end

    test "reset empties the buffer immediately" do
      chunker = SentenceChunker.new()
      {_, chunker} = SentenceChunker.push(chunker, "Incomplete barge-in text")
      reset_chunker = SentenceChunker.reset(chunker)

      assert reset_chunker.buffer == ""
      assert reset_chunker.first_chunk_sent == false
    end
  end
end
