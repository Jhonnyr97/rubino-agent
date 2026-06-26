# frozen_string_literal: true

require "json"

module Rubino
  module LLM
    # Recovers tool calls that a model LEAKED AS TEXT into its assistant
    # content — instead of returning them in the structured tool_calls field —
    # and strips the leaked markup from the visible/saved text.
    #
    # WHY: some models are trained to emit tool calls as markup (XML/JSON in
    # tags) that a server-side parser is supposed to convert to structured
    # calls. When that conversion fails (e.g. MiniMax's Anthropic-compatible
    # shim), the raw markup + channel tokens leak into the text: the tool never
    # runs (the model "describes" instead of "does") and the junk poisons the
    # saved history so the model mimics its own broken format next turn.
    #
    # This mirrors the vLLM / SGLang per-model tool-call parsers and OpenHands'
    # fn_call_converter: parse the markup back into {name, arguments} and run it.
    # It covers the THREE format-families that account for ~80% of open models:
    #
    #   A) JSON-in-<tool_call>     — Hermes, Qwen2.5/Qwen3
    #   B) XML invoke/parameter    — MiniMax-M2/M3, Qwen3-Coder
    #   C) [TOOL_CALLS] JSON-array — Mistral / Mixtral
    #
    # Conventions copied from those parsers: peel reasoning <think> FIRST; use a
    # two-branch "closed | unterminated-to-EOF" match so a missing close tag is
    # still recovered.
    module ToolCallRecovery
      # {text:} is the content with all recovered markup removed (what the user
      # sees and what gets saved); {calls:} is the list of recovered tool calls,
      # each {name:, arguments:} with arguments a Hash.
      Recovered = Struct.new(:text, :calls, keyword_init: true)

      # MiniMax-M3 prefixes this literal channel/namespace marker on EVERY tag
      # of a leaked tool call (a garbled render of its turn delimiters). Strip it
      # everywhere so the inner <tool_call>/<invoke> structure is parseable, and
      # so it never shows/poisons even when no call is recovered.
      MINIMAX_NS = "]<]minimax[>["

      # Reasoning blocks some models leak into content. Peeled before extraction
      # (mirrors the upstream reasoning-parser layer) so a tool call mentioned
      # INSIDE reasoning never fires and the scratchpad never shows.
      THINK_BLOCK = %r{<(think|thinking|reasoning|thought)\b[^>]*>.*?</\1>}im

      # Family B — one tool call: <invoke name="fn"> … </invoke> (closed, or
      # unterminated to EOF). The body holds the parameters.
      #
      # TOLERANT to MiniMax-M3's GARBLED leak: M3's namespace special token
      # `]<]minimax[>[` (id 200058) carries the literal chars ] < [ > which
      # collide with XML delimiters, so the gateway routinely mis-segments the
      # tag and drops `name=`, leaving forms like `<invoke">shell">` or
      # `invoke name="shell">` (documented: llama.cpp #24523, mlx-lm #1145). The
      # canonical vLLM/SGLang parsers hard-require `<invoke name="` and recover
      # NONE of these. So we eat any garbled punctuation between `invoke` and the
      # first identifier-like token, and capture that token as the tool name —
      # recovering the name from the well-formed AND every garbled variant.
      INVOKE = %r{
        <?invoke                       # optional leading < (M3 drops it too)
        [^A-Za-z0-9_]*                 # garbled punctuation: ">, ", stray brackets
        (?:name\s*=\s*)?               # the name= attribute, when it survives
        ["']?\s*([A-Za-z_][\w.-]*)\s*["']?  # the tool name (bareword identifier)
        \s*>                           # close of the opening tag
        (.*?)(?:</invoke>|\z)          # body up to </invoke> or EOF
      }imx

      # Family B parameters, two dialects inside an <invoke> body:
      #   <parameter name="key">value</parameter>   (MiniMax-M2)
      #   <key>value</key>                            (bare element = param name)
      PARAM_NAMED = %r{<parameter\s+name="([^"]+)"\s*>(.*?)(?:</parameter>|\z)}im
      PARAM_BARE  = %r{<([a-zA-Z_][\w-]*)\s*>(.*?)</\1>}im

      # Family A — JSON in <tool_call> … </tool_call> (closed | unterminated).
      TOOL_CALL_JSON = %r{<tool_call>\s*(\{.*?\})\s*(?:</tool_call>|\z)}im

      # Family C — Mistral: [TOOL_CALLS] then a JSON array of calls.
      TOOL_CALLS_ARRAY = /\[TOOL_CALLS\]\s*(\[.*\])/im

      # Bare wrappers left over after the inner calls are extracted, removed so
      # no orphan tags remain in the cleaned text.
      ORPHAN_WRAPPERS = %r{</?(?:tool_call|minimax:tool_call|invoke|tool_calls)\b[^>]*>}im

      module_function

      def recover(content)
        text = content.to_s
        return Recovered.new(text: text, calls: []) if text.empty?

        text = text.gsub(MINIMAX_NS, "")
        text = text.gsub(THINK_BLOCK, "")

        calls = []
        text = extract_invoke!(text, calls) # B
        text = extract_tool_call_json!(text, calls) # A
        text = extract_tool_calls_array!(text, calls) if calls.empty? # C

        text = text.gsub(ORPHAN_WRAPPERS, "") unless calls.empty?
        Recovered.new(text: text.strip, calls: calls)
      end

      # --- family B: <invoke name="fn"><param…></invoke> -------------------
      def extract_invoke!(text, calls)
        text.gsub(INVOKE) do
          name = Regexp.last_match(1)
          body = Regexp.last_match(2).to_s
          calls << { name: name, arguments: parse_invoke_params(body) }
          ""
        end
      end

      def parse_invoke_params(body)
        args = {}
        body.scan(PARAM_NAMED) { |k, v| args[k] = coerce(v.strip) }
        # Bare child elements as params, but only outside the <parameter …> ones
        # already consumed (and never the <parameter> tag itself).
        body.gsub(PARAM_NAMED, "").scan(PARAM_BARE) do |k, v|
          next if k.casecmp("parameter").zero?

          args[k] = coerce(v.strip)
        end
        args
      end

      # --- family A: <tool_call>{json}</tool_call> -------------------------
      def extract_tool_call_json!(text, calls)
        text.gsub(TOOL_CALL_JSON) do
          json = Regexp.last_match(1)
          obj  = safe_json(json)
          if obj.is_a?(Hash) && obj["name"]
            calls << { name: obj["name"], arguments: normalize_args(obj["arguments"]) }
            ""
          else
            Regexp.last_match(0) # leave untouched if not a real call
          end
        end
      end

      # --- family C: [TOOL_CALLS][{...}] ----------------------------------
      def extract_tool_calls_array!(text, calls)
        text.gsub(TOOL_CALLS_ARRAY) do
          arr = safe_json(Regexp.last_match(1))
          if arr.is_a?(Array)
            arr.each do |c|
              next unless c.is_a?(Hash) && c["name"]

              calls << { name: c["name"], arguments: normalize_args(c["arguments"]) }
            end
            ""
          else
            Regexp.last_match(0)
          end
        end
      end

      # --- helpers ---------------------------------------------------------
      def normalize_args(args)
        case args
        when Hash   then args
        when String then safe_json(args).is_a?(Hash) ? safe_json(args) : { "value" => args }
        else {}
        end
      end

      # A leaked XML parameter value is always a string on the wire; keep it a
      # string (the tool schema coerces). Only unwrap an obvious JSON scalar.
      def coerce(value)
        value
      end

      def safe_json(str)
        JSON.parse(str)
      rescue JSON::ParserError, TypeError
        nil
      end
    end
  end
end
