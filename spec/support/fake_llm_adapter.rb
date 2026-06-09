# frozen_string_literal: true

# FakeLLMAdapter — a scriptable in-process LLM double for use in specs.
#
# Usage:
#
#   fake = FakeLLMAdapter.new
#
#   # Queue plain text responses (returned as text_only AdapterResponse)
#   fake.enqueue_text("Hello, I can help with that.")
#
#   # Queue a tool call response
#   fake.enqueue_tool_call("read", { "file_path" => "foo.rb" })
#
#   # After all queued responses are consumed, further calls raise or return a
#   # configurable fallback.
#
#   adapter = fake  # pass as llm_adapter: to Agent::Loop
#
# Inspection helpers:
#
#   fake.call_count          # how many times chat/stream was called
#   fake.calls               # array of { messages:, tools: } for each call
#   fake.exhausted?          # true when the queue is empty

class FakeLLMAdapter
  # Raised when the adapter is called unexpectedly (queue exhausted)
  class UnexpectedCallError < StandardError; end

  attr_reader :calls

  def initialize
    @queue = []
    @calls = []
  end

  # ---------------------------------------------------------------------------
  # Scripting helpers
  # ---------------------------------------------------------------------------

  # Enqueue a plain-text assistant response.
  def enqueue_text(content, input_tokens: 10, output_tokens: 20)
    @queue << build_text_response(content, input_tokens, output_tokens)
    self
  end

  # Enqueue an assistant message that contains a single tool call.
  def enqueue_tool_call(tool_name, arguments, call_id: nil, content: nil,
                        input_tokens: 10, output_tokens: 15)
    @queue << build_tool_call_response(tool_name, arguments, call_id, content,
                                       input_tokens, output_tokens)
    self
  end

  # Enqueue an assistant message with multiple tool calls.
  def enqueue_tool_calls(tool_calls_list, content: nil, input_tokens: 10, output_tokens: 15)
    tool_calls = tool_calls_list.map.with_index do |(name, args), idx|
      { id: "call_#{idx}_#{SecureRandom.hex(4)}", name: name, arguments: args }
    end
    @queue << Rubino::LLM::AdapterResponse.new(
      content: content || "",
      tool_calls: tool_calls,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      model_id: "fake-model"
    )
    self
  end

  # Enqueue a streaming turn that runs tools mid-stream the way the real
  # adapter does: in streaming mode ruby_llm dispatches tool calls THROUGH the
  # ToolBridge into ToolExecutor#execute as it streams, then the assistant
  # message that finally lands is plain text (tool_calls: []). The Loop never
  # sees a has_tool_calls? response on the streaming path. This double mirrors
  # that: it invokes the given executor once per tool BEFORE yielding the final
  # text, so the Loop's on_result sink (count + persist) is exercised exactly
  # like production. `tool_calls` is a list of [name, args] pairs.
  def enqueue_streaming_tool_turn(executor, tool_calls, final_text)
    @queue << build_text_response(final_text, 10, 20)
    @stream_side_effect = lambda do
      tool_calls.each do |name, args|
        executor.execute(name: name, arguments: args, call_id: "call_#{SecureRandom.hex(4)}")
      end
    end
    self
  end

  # Enqueue a response that raises an error when consumed.
  def enqueue_error(message = "Simulated LLM error")
    @queue << RuntimeError.new(message)
    self
  end

  # Enqueue a degenerate "empty" response: no text AND no tool calls, NOT
  # interrupted. The model returned 200 OK but nothing usable — the Loop must
  # retry the turn and ultimately raise EmptyModelResponseError, never report it
  # as completed. (MiniMax-M2.7 "completed but empty" symptom.)
  def enqueue_empty(content: nil, input_tokens: 5, output_tokens: 0)
    @queue << Rubino::LLM::AdapterResponse.new(
      content: content,
      tool_calls: [],
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      model_id: "fake-model"
    )
    self
  end

  # Enqueue a response truncated by the output-token limit: stop_reason==:length
  # with no tool calls. Mirrors what the non-streaming adapter path surfaces from
  # the raw body when the model hit max_tokens. Drives Agent::TruncationContinuation.
  def enqueue_truncated(content, input_tokens: 10, output_tokens: 20)
    @queue << Rubino::LLM::AdapterResponse.new(
      content: content,
      tool_calls: [],
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      model_id: "fake-model",
      stop_reason: :length
    )
    self
  end

  # Enqueue a truncated-stream partial: the adapter would return this when the
  # upstream connection dropped mid-stream (interrupted: true). The Loop must
  # fail the turn on it, never report it as a completed answer.
  def enqueue_interrupted(content = "partial", input_tokens: 5, output_tokens: 3)
    @queue << Rubino::LLM::AdapterResponse.new(
      content: content,
      tool_calls: [],
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      model_id: "fake-model",
      interrupted: true
    )
    self
  end

  # ---------------------------------------------------------------------------
  # LLM adapter interface (matches Rubino::LLM::RubyLLMAdapter)
  # ---------------------------------------------------------------------------

  # LLM boundary entry: dispatch an LLM::Request to chat
  # or stream so specs that build a Loop drive the fake through the same seam
  # the real adapter exposes.
  def call(request, &)
    if request.stream?
      stream(messages: request.messages, tools: request.tools,
             image_paths: request.image_paths, &)
    else
      chat(messages: request.messages, tools: request.tools,
           image_paths: request.image_paths)
    end
  end

  def chat(messages:, tools: nil, response_format: nil, image_paths: nil)
    record_call(messages: messages, tools: tools, image_paths: image_paths)
    consume_next!
  end

  def stream(messages:, tools: nil, response_format: nil, image_paths: nil)
    record_call(messages: messages, tools: tools, image_paths: image_paths)
    # Run any mid-stream tool side-effect (ToolBridge → executor) before the
    # final assistant text, mirroring the real streaming dispatch order.
    if @stream_side_effect
      side_effect = @stream_side_effect
      @stream_side_effect = nil
      side_effect.call
    end
    response = consume_next!
    # Simulate streaming: yield each word as a chunk in the SAME uniform chunk
    # contract every real adapter emits — { type:, text:, message_id: } — never
    # a bare String, so the UI never has to branch on Hash-vs-String.
    if block_given? && response.content
      response.content.split(" ").each_with_index do |word, idx|
        text = idx.zero? ? word : " #{word}"
        yield({ type: :content, text: text, message_id: 0 })
      end
    end
    response
  end

  # Stub — not needed for tests but prevents NoMethodError
  def model_info = nil
  def context_window = 128_000

  # ---------------------------------------------------------------------------
  # Inspection
  # ---------------------------------------------------------------------------

  def call_count = @calls.size
  def exhausted? = @queue.empty?

  # Returns all messages arrays passed to chat/stream calls
  def received_messages = @calls.map { |c| c[:messages] }

  # Clears call log and response queue (useful in before blocks)
  def reset!
    @queue.clear
    @calls.clear
    self
  end

  private

  def record_call(messages:, tools:, image_paths: nil)
    @calls << { messages: messages, tools: tools, image_paths: image_paths, called_at: Time.now }
  end

  def consume_next!
    raise UnexpectedCallError, "FakeLLMAdapter queue is exhausted — no more responses scripted" if @queue.empty?

    next_item = @queue.shift
    raise next_item if next_item.is_a?(Exception)

    next_item
  end

  def build_text_response(content, input_tokens, output_tokens)
    Rubino::LLM::AdapterResponse.new(
      content: content,
      tool_calls: [],
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      model_id: "fake-model"
    )
  end

  def build_tool_call_response(tool_name, arguments, call_id, content, input_tokens, output_tokens)
    Rubino::LLM::AdapterResponse.new(
      content: content || "",
      tool_calls: [{ id: call_id || "call_#{SecureRandom.hex(6)}", name: tool_name, arguments: arguments }],
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      model_id: "fake-model"
    )
  end
end
