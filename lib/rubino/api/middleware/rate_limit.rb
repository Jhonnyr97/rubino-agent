# frozen_string_literal: true

require "json"

module Rubino
  module API
    module Middleware
      # Token-bucket rate limiter, applied BEFORE Auth so that the open
      # endpoints (/v1/health, /v1/metrics) get their own per-IP ceiling and
      # cannot be flooded by an unauthenticated client. Authenticated requests
      # are keyed by the bearer token so a single API key cannot saturate the
      # process by spraying connections from many IPs.
      #
      # Buckets refill linearly over a 60-second window. Storage is a single
      # in-memory hash with monotonic timestamps; safe for a single-process
      # deployment. Multi-process / multi-host needs a shared backend
      # (Redis, etc.) — defer until we actually scale out.
      #
      # On exceed: 429 with the canonical error envelope
      #   { error: { code: "rate_limited", message: "...",
      #              details: { retry_after_seconds: N } } }
      # and a Retry-After header so well-behaved clients can back off without
      # parsing the body.
      class RateLimit
        DEFAULT_UNAUTH_PER_MINUTE = 60
        DEFAULT_AUTH_PER_MINUTE   = 600
        WINDOW_SECONDS            = 60.0

        def initialize(app, clock: nil)
          @app = app
          @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
          @buckets = {}
          @mutex = Mutex.new
        end

        def call(env)
          return @app.call(env) unless enabled?

          key, capacity = bucket_for(env)
          allowed, retry_after = consume(key, capacity)
          return too_many(retry_after) unless allowed

          @app.call(env)
        end

        private

        # Authenticated buckets are keyed by the bearer token (so the same key
        # used from many IPs still hits one ceiling); unauthenticated buckets
        # are keyed by remote IP. The auth/unauth split is decided by whether
        # the request advertised a Bearer token at all — Auth itself validates
        # the token later, so an invalid token still gets the unauth bucket
        # via REMOTE_ADDR if we cannot extract one.
        def bucket_for(env)
          token = bearer_token(env)
          if token
            ["auth:#{token}", auth_limit]
          else
            ["ip:#{env["REMOTE_ADDR"] || "unknown"}", unauth_limit]
          end
        end

        def bearer_token(env)
          header = env["HTTP_AUTHORIZATION"].to_s
          match = header.match(/\ABearer (.+)\z/i)
          match && match[1]
        end

        # Refill is continuous: tokens accumulate at capacity/window per second,
        # capped at capacity. Each request costs 1 token. Returns
        # [allowed?, retry_after_seconds_when_denied].
        def consume(key, capacity)
          now = @clock.call
          @mutex.synchronize do
            bucket = @buckets[key] ||= { tokens: capacity.to_f, updated_at: now }
            elapsed = now - bucket[:updated_at]
            refill_rate = capacity / WINDOW_SECONDS
            bucket[:tokens] = [bucket[:tokens] + (elapsed * refill_rate), capacity.to_f].min
            bucket[:updated_at] = now

            if bucket[:tokens] >= 1
              bucket[:tokens] -= 1
              [true, 0]
            else
              # Time until one full token is available again.
              deficit = 1 - bucket[:tokens]
              retry_after = (deficit / refill_rate).ceil
              [false, [retry_after, 1].max]
            end
          end
        end

        def too_many(retry_after)
          payload = {
            error: {
              code: "rate_limited",
              message: "rate limit exceeded",
              details: { retry_after_seconds: retry_after }
            }
          }
          [
            429,
            {
              "content-type" => "application/json",
              "retry-after" => retry_after.to_s
            },
            [JSON.generate(payload)]
          ]
        end

        def enabled?
          value = config_dig("api", "rate_limit_enabled")
          value.nil? || value == true
        end

        def unauth_limit
          int_or(config_dig("api", "rate_limit_unauth_per_minute"), DEFAULT_UNAUTH_PER_MINUTE)
        end

        def auth_limit
          int_or(config_dig("api", "rate_limit_auth_per_minute"), DEFAULT_AUTH_PER_MINUTE)
        end

        def int_or(value, fallback)
          value.is_a?(Integer) && value.positive? ? value : fallback
        end

        def config_dig(*keys)
          Rubino.configuration.dig(*keys)
        rescue StandardError
          nil
        end
      end
    end
  end
end
